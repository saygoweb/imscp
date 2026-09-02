=head1 NAME

 Servers::po::courier::installer - i-MSCP Courier IMAP/POP3 Server installer implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-201 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package Servers::po::courier::installer;

use strict;
use warnings;
use File::Spec;
use File::Temp;
use iMSCP::Boolean;
use iMSCP::Config;
use iMSCP::Crypt qw/ ALPHA64 decryptRijndaelCBC encryptRijndaelCBC randomStr /;
use iMSCP::Database;
use iMSCP::Debug qw/ debug error warning /;
use iMSCP::Dir;
use iMSCP::EventManager;
use iMSCP::Execute qw/ execute executeNoWait /;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::Mount qw/ addMountEntry isMountpoint mount umount /;
use iMSCP::ProgramFinder;
use iMSCP::Stepper qw/ startDetail endDetail step /;
use iMSCP::Service;
use iMSCP::SystemUser;
use iMSCP::TemplateParser qw/ process replaceBloc /;
use iMSCP::Umask '$UMASK';
use Servers::mta::postfix;
use Servers::po::courier;
use Servers::sqld;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP Courier IMAP/POP3 Server installer implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners( \%events )

 Register setup event listeners

 Param iMSCP::EventManager \%events
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    my ( $self, $events ) = @_;

    my $rs = $events->register(
        'beforeMtaBuildMainCfFile', sub { $self->configurePostfix( @_ ); }
    );
    $rs ||= $events->register(
        'beforeMtaBuildMasterCfFile', sub { $self->configurePostfix( @_ ); }
    );
}

=item preinstall( )

 Pre-installation tasks

 Return int 0 on success, other on failure

=cut

sub preinstall
{
    my ( $self ) = @_;

    #$self->{'po'}->stop();
    0;
}

=item install( )

 Installation tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my ( $self ) = @_;

    my $rs = $self->_setupSqlUser();
    $rs ||= $self->_buildConf();
    $rs ||= $self->_setupSASL();
    $rs ||= $self->_migrateFromDovecot();
    $rs ||= $self->_oldEngineCompatibility();
}

=item postinstall( )

 Post-installation tasks

 Return int 0 on success, other on failure

=cut

sub postinstall
{
    my ( $self ) = @_;

    local $@;
    eval {
        my @toEnableServices = (
            'AUTHDAEMON_SNAME', 'POPD_SNAME', 'IMAPD_SNAME'
        );
        my @toDisableServices = ();

        if ( $::imscpConfig{'SERVICES_SSL_ENABLED'} eq 'yes' ) {
            push @toEnableServices, 'POPD_SSL_SNAME', 'IMAPD_SSL_SNAME';
        } else {
            push @toDisableServices, 'POPD_SSL_SNAME', 'IMAPD_SSL_SNAME';
        }

        my $serviceMngr = iMSCP::Service->getInstance();
        for my $service ( @toEnableServices ) { ;
            $serviceMngr->enable( $self->{'config'}->{$service} );
        }

        for my $service ( @toDisableServices ) {
            $serviceMngr->stop( $self->{'config'}->{$service} );
            $serviceMngr->disable( $self->{'config'}->{$service} );
        }
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $self->{'events'}->register(
        'beforeSetupRestartServices',
        sub {
            push @{ $_[0] }, [
                sub { $self->{'po'}->restart(); },
                'Courier IMAP/POP, Courier Authdaemon'
            ];
            0;
        },
        5
    );
}

=back

=head1 EVENT LISTENERS

=over 4

=item configurePostfix( \$fileContent, $fileName )

 Injects configuration for both, maildrop MDA and Cyrus SASL in Postfix configuration files.

 Listener that listen on the following events:
  - beforeMtaBuildMainCfFile
  - beforeMtaBuildMasterCfFile

 Param string \$fileContent Configuration file content
 Param string $fileName Configuration filename
 Return int 0 on success, other on failure

=cut

sub configurePostfix
{
    my ( $self, $fileContent, $fileName ) = @_;

    if ( $fileName eq 'main.cf' ) {
        return $self->{'events'}->register( 'afterMtaBuildConf', sub {
            $self->{'mta'}->postconf( (
                # Maildrop MDA parameters
                virtual_transport                      => {
                    action => 'replace',
                    values => [ 'maildrop' ]
                },
                maildrop_destination_concurrency_limit => {
                    action => 'replace',
                    values => [ '2' ]
                },
                maildrop_destination_recipient_limit   => {
                    action => 'replace',
                    values => [ '1' ]
                },
                # Cyrus SASL parameters
                smtpd_sasl_type                        => {
                    action => 'replace',
                    values => [ 'cyrus' ]
                },
                # Tell Cyrus SASL where smtpd.conf actually is. Up to Debian
                # 11 libsasl2 found /etc/postfix/sasl unaided; from Debian 12
                # it does not, and Postfix silently falls back to SASL's own
                # defaults - advertising every mechanism instead of the
                # configured MECH_LIST, and using auxprop instead of
                # authdaemond. Every SMTP AUTH then fails with "unable to
                # canonify user and get auxprops".
                cyrus_sasl_config_path                 => {
                    action => 'replace',
                    values => [ $self->{'config'}->{'SASL_CONF_DIR'} ]
                },
                smtpd_sasl_path                        => {
                    action => 'replace',
                    values => [ 'smtpd' ]
                },
                smtpd_sasl_auth_enable                 => {
                    action => 'replace',
                    values => [ 'yes' ]
                },
                smtpd_sasl_security_options            => {
                    action => 'replace',
                    values => [ 'noanonymous' ]
                },
                smtpd_sasl_authenticated_header        => {
                    action => 'replace',
                    values => [ 'yes' ]
                },
                broken_sasl_auth_clients               => {
                    action => 'replace',
                    values => [ 'yes' ]
                },
                # SMTP restrictions
                smtpd_helo_restrictions                => {
                    action => 'add',
                    values => [ 'permit_sasl_authenticated' ],
                    after  => qr/permit_mynetworks/
                },
                smtpd_sender_restrictions              => {
                    action => 'add',
                    values => [ 'permit_sasl_authenticated' ],
                    after  => qr/permit_mynetworks/
                },
                smtpd_recipient_restrictions           => {
                    action => 'add',
                    values => [ 'permit_sasl_authenticated' ],
                    after  => qr/permit_mynetworks/
                }
            ));
        } );
    }

    if ( $fileName eq 'master.cf' ) {
        ${ $fileContent } .= process(
            {
                MTA_MAILBOX_UID_NAME => $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'},
                MTA_MAILBOX_GID_NAME => $self->{'mta'}->{'config'}->{'MTA_MAILBOX_GID_NAME'}
            },
            <<'EOF'
maildrop  unix  -       n       n       -       -       pipe
 flags=DRhu user={MTA_MAILBOX_UID_NAME}:{MTA_MAILBOX_GID_NAME} argv=maildrop -w 90 -d ${user}@${nexthop} ${extension} ${recipient} ${user} ${nexthop} ${sender}
EOF
        );
    }

    0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize instance

 Return Servers::po::courier::installer

=cut

sub _init
{
    my ( $self ) = @_;

    $self->{'events'} = iMSCP::EventManager->getInstance();
    $self->{'po'} = Servers::po::courier->getInstance();
    $self->{'mta'} = Servers::mta::postfix->getInstance();
    $self->{'cfgDir'} = $self->{'po'}->{'cfgDir'};
    $self->{'config'} = $self->{'po'}->{'config'};
    $self;
}

=item _setupSqlUser( )

 Setup SQL user

 Return int 0 on success, other on failure

=cut

sub _setupSqlUser
{
    my ( $self ) = @_;

    my $rs = eval {
        my $dbh = iMSCP::Database->factory()->getRawDb();
        my %config = @{ $dbh->selectcol_arrayref(
            "
                SELECT `name`, `value`
                FROM `config`
                WHERE `name` LIKE 'COURIER_AUTHDAEMON_SQL_%'
            ",
            { Columns => [ 1, 2 ] }
        ) };

        if ( length $config{'COURIER_AUTHDAEMON_SQL_USER'} ) {
            $config{'COURIER_AUTHDAEMON_SQL_USER'} = decryptRijndaelCBC(
                $::imscpDBKey,
                $::imscpDBiv,
                $config{'COURIER_AUTHDAEMON_SQL_USER'}
            );
        } else {
            $config{'COURIER_AUTHDAEMON_SQL_USER'} = 'courier_' . randomStr(
                8, ALPHA64
            );
        }

        if ( length $config{'COURIER_AUTHDAEMON_SQL_USER_PASSWD'} ) {
            $config{'COURIER_AUTHDAEMON_SQL_USER_PASSWD'} = decryptRijndaelCBC(
                $::imscpDBKey,
                $::imscpDBiv,
                $config{'COURIER_AUTHDAEMON_SQL_USER_PASSWD'}
            );
        } else {
            $config{'COURIER_AUTHDAEMON_SQL_USER_PASSWD'} = randomStr(
                16, ALPHA64
            );
        }

        (
            $self->{'_courier_authdaemon_sql_user'},
            $self->{'_courier_authdaemon_sql_user_passwd'}
        ) = (
            $config{'COURIER_AUTHDAEMON_SQL_USER'},
            $config{'COURIER_AUTHDAEMON_SQL_USER_PASSWD'}
        );

        $dbh->do(
            '
                INSERT INTO `config` (`name`,`value`)
                VALUES (?,?),(?,?)
                ON DUPLICATE KEY UPDATE `name` = `name`
            ',
            undef,
            'COURIER_AUTHDAEMON_SQL_USER',
            encryptRijndaelCBC(
                $::imscpDBKey,
                $::imscpDBiv,
                $config{'COURIER_AUTHDAEMON_SQL_USER'}
            ),
            'COURIER_AUTHDAEMON_SQL_USER_PASSWD',
            encryptRijndaelCBC(
                $::imscpDBKey,
                $::imscpDBiv,
                $config{'COURIER_AUTHDAEMON_SQL_USER_PASSWD'}
            )
        );

        my $sqlServer = Servers::sqld->factory();

        for my $host (
            $::imscpOldConfig{'DATABASE_USER_HOST'},
            ::setupGetQuestion( 'DATABASE_USER_HOST' )
        ) {
            next unless length $host;
            for my $user (
                $config{'COURIER_AUTHDAEMON_SQL_USER'},
                $self->{'dovecot'}->{'oldConfig'}->{'DATABASE_USER'} # Transitional
            ) {
                next unless length $user;
                $sqlServer->dropUser( $user, $host );
            }
        }

        $sqlServer->createUser(
            $config{'COURIER_AUTHDAEMON_SQL_USER'},
            ::setupGetQuestion( 'DATABASE_USER_HOST' ),
            $config{'COURIER_AUTHDAEMON_SQL_USER_PASSWD'},
        );

        $dbh->do(
            "
                GRANT SELECT
                ON `@{ [ ::setupGetQuestion( 'DATABASE_NAME' ) ] }`.`mail_users`
                TO ?\@?
            ",
            undef,
            $config{'COURIER_AUTHDAEMON_SQL_USER'},
            ::setupGetQuestion( 'DATABASE_USER_HOST' )
        );

        0;
    };
    if ( $@ ) {
        error( $@ );
        $rs = 1;
    }

    $rs;
}

=item _buildConf( )

 Build courier configuration files

 Return int 0 on success, other on failure

=cut

sub _buildConf
{
    my ( $self ) = @_;

    my $rs = $self->_buildDHparametersFile();
    $rs ||= $self->_buildAuthdaemonrcFile();
    $rs ||= $self->_buildSslConfFiles();
    return $rs if $rs;

    my $data = {
        DATABASE_HOST        => ::setupGetQuestion( 'DATABASE_HOST' ),
        DATABASE_PORT        => ::setupGetQuestion( 'DATABASE_PORT' ),
        DATABASE_USER        => $self->{'_courier_authdaemon_sql_user'},
        DATABASE_PASSWORD    => $self->{'_courier_authdaemon_sql_user_passwd'},
        DATABASE_NAME        => ::setupGetQuestion( 'DATABASE_NAME' ),
        HOST_NAME            => ::setupGetQuestion( 'SERVER_HOSTNAME' ),
        MTA_MAILBOX_UID      => ( scalar getpwnam( $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'} ) ),
        MTA_MAILBOX_GID      => ( scalar getgrnam( $self->{'mta'}->{'config'}->{'MTA_MAILBOX_GID_NAME'} ) ),
        MTA_VIRTUAL_MAIL_DIR => $self->{'mta'}->{'config'}->{'MTA_VIRTUAL_MAIL_DIR'}
    };

    my %cfgFiles = (
        authmysqlrc     => [
            "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/authmysqlrc", # Dest path
            $self->{'config'}->{'AUTHDAEMON_USER'},                # Owner
            $self->{'config'}->{'AUTHDAEMON_GROUP'},               # Group
            0640                                                   # Permissions
        ],
        'quota-warning' => [
            $self->{'config'}->{'QUOTA_WARN_MSG_PATH'},           # Dest path
            $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'}, # Owner
            $::imscpConfig{'ROOT_GROUP'},                         # Group
            0640                                                  # Permissions
        ]
    );

    {
        local $UMASK = 027; # authmysqlrc file must not be created/copied world-readable

        for my $conffile ( keys %cfgFiles ) {
            $rs = $self->{'events'}->trigger(
                'onLoadTemplate', 'courier', $conffile, \my $cfgTpl, $data
            );
            return $rs if $rs;

            unless ( defined $cfgTpl ) {
                return 1 unless defined(
                    $cfgTpl = iMSCP::File->new(
                        filename => "$self->{'cfgDir'}/$conffile"
                    )->get()
                );
            }

            $rs = $self->{'events'}->trigger(
                'beforePoBuildConf', \$cfgTpl, $conffile
            );
            return $rs if $rs;

            $cfgTpl = process( $data, $cfgTpl );

            if ( $conffile eq 'authmysqlrc' ) {
                $rs = $self->_preserveAuthlibMarkers(
                    \$cfgTpl, $cfgFiles{$conffile}->[0]
                );
                return $rs if $rs;
            }

            $rs = $self->{'events'}->trigger(
                'afterPoBuildConf', \$cfgTpl, $conffile
            );
            return $rs if $rs;

            my $file = iMSCP::File->new(
                filename => $cfgFiles{$conffile}->[0]
            );
            $file->set( $cfgTpl );

            $rs = $file->save();
            $rs ||= $file->owner(
                $cfgFiles{$conffile}->[1], $cfgFiles{$conffile}->[2]
            );
            $rs ||= $file->mode( $cfgFiles{$conffile}->[3] );
            return $rs if $rs;
        }
    }

    return 0 unless -f "$self->{'cfgDir'}/imapd.local";

    my $file = iMSCP::File->new(
        filename => "$self->{'config'}->{'COURIER_CONF_DIR'}/imapd"
    );
    return 1 unless defined( my $fileContent = $file->get());

    $fileContent = replaceBloc(
        qr/(:?^\n)?# Servers::po::courier::installer - BEGIN\n/m,
        qr/# Servers::po::courier::installer - ENDING\n/,
        '',
        $fileContent
    );

    $fileContent .= <<"EOF";

# Servers::po::courier::installer - BEGIN
. $self->{'cfgDir'}/imapd.local
# Servers::po::courier::installer - ENDING
EOF
    $file->set( $fileContent );
    $rs = $file->save();
    $rs ||= $file->owner(
        $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'}
    );
    $rs ||= $file->mode( 0644 );
}

=item _setupSASL( )

 Setup SASL for Postfix

 Return int 0 on success, other on failure

=cut

sub _setupSASL
{
    my ( $self ) = @_;

    # Add postfix user in `mail' group to make it able to access
    # authdaemon rundir
    my $rs = iMSCP::SystemUser->new()->addToGroup(
        $self->{'mta'}->{'config'}->{'MTA_MAILBOX_GID_NAME'},
        $self->{'mta'}->{'config'}->{'POSTFIX_USER'}
    );
    return $rs if $rs;

    # Mount authdaemon socket directory in Postfix chroot
    # Postfix won't be able to connect to socket located outside of its chroot
    my $fsSpec = File::Spec->canonpath(
        $self->{'config'}->{'AUTHLIB_SOCKET_DIR'}
    );
    my $fsFile = File::Spec->canonpath(
        "$self->{'mta'}->{'config'}->{'POSTFIX_QUEUE_DIR'}/$self->{'config'}->{'AUTHLIB_SOCKET_DIR'}"
    );
    my $fields = {
        fs_spec    => $fsSpec,
        fs_file    => $fsFile,
        fs_vfstype => 'none',
        fs_mntops  => 'bind,slave'
    };

    local $@;
    eval { iMSCP::Dir->new( dirname => $fsFile )->make(); };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $rs = addMountEntry(
        "$fields->{'fs_spec'} $fields->{'fs_file'} $fields->{'fs_vfstype'} $fields->{'fs_mntops'}"
    );

    # isMountpoint() alone is not enough. courier-authdaemon declares
    # RuntimeDirectory=, so systemd deletes and recreates the source directory
    # on every restart - and the bind mount is then still a mountpoint, but
    # attached to the old, unlinked inode. The socket vanishes from inside the
    # Postfix chroot while everything still looks mounted, and every SMTP AUTH
    # fails until someone notices. Treat a mount whose socket is not visible as
    # stale and redo it.
    my $socketInChroot = "$fields->{'fs_file'}/socket";
    if ( isMountpoint( $fields->{'fs_file'} ) && !-S $socketInChroot ) {
        debug( sprintf(
            '%s is mounted but %s is not visible; remounting',
            $fields->{'fs_file'}, $socketInChroot
        ));
        $rs ||= umount( $fields->{'fs_file'} );
    }

    $rs ||= mount( $fields ) unless isMountpoint( $fields->{'fs_file'} );

    # And keep it that way. Without this the mount is correct now and broken
    # the next time anything restarts the authentication daemon.
    $rs ||= $self->_installAuthdaemonMountDropIn( $fields );

    # Build Cyrus SASL smtpd.conf configuration file

    $rs ||= $self->{'events'}->trigger(
        'onLoadTemplate', 'courier', 'smtpd.conf', \my $cfgTpl
    );
    return $rs if $rs;

    unless ( defined $cfgTpl ) {
        return 1 unless defined(
            $cfgTpl = iMSCP::File->new(
                filename => "$self->{'cfgDir'}/sasl/smtpd.conf"
            )->get()
        );
    }

    $cfgTpl = process(
        {
            PWCHECK_METHOD  => $self->{'config'}->{'PWCHECK_METHOD'},
            LOG_LEVEL       => $self->{'config'}->{'LOG_LEVEL'},
            MECH_LIST       => $self->{'config'}->{'MECH_LIST'},
            AUTHDAEMON_PATH => $self->{'config'}->{'AUTHDAEMON_PATH'}
        },
        $cfgTpl
    );

    local $UMASK = 027; # smtpd.conf file must not be created/copied world-readable

    my $file = iMSCP::File->new(
        filename => "$self->{'config'}->{'SASL_CONF_DIR'}/smtpd.conf"
    );
    $file->set( $cfgTpl );
    $rs = $file->save();
    $rs ||= $file->owner(
        $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'}
    );
    $rs ||= $file->mode( 0640 );
}

=item _buildDHparametersFile( )

 Build the DH parameters file with a stronger size (2048 instead of 768)

 Fix: #IP-1401
 Return int 0 on success, other on failure

=cut

sub _buildDHparametersFile
{
    my ( $self ) = @_;

    return 0 unless iMSCP::ProgramFinder::find(
        'certtool'
    ) || iMSCP::ProgramFinder::find(
        'mkdhparams'
    );

    if ( -f "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem" ) {
        my $rs = execute(
            [
                'openssl',
                'dhparam',
                '-in', "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem",
                '-text',
                '-noout'
            ],
            \my $stdout,
            \my $stderr
        );
        debug( $stderr || 'Unknown error' ) if $rs;
        if ( $rs == 0 && $stdout =~ /\((\d+)\s+bit\)/ && $1 >= 2048 ) {
            return 0; # Don't regenerate file if not needed
        }

        $rs = iMSCP::File->new(
            filename => "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem"
        )->delFile();
        return $rs if $rs;
    }

    startDetail();

    my $rs = step(
        sub {
            my ( $tmpFile, $cmd );

            if ( iMSCP::ProgramFinder::find( 'certtool' ) ) {
                $tmpFile = File::Temp->new( UNLINK => FALSE );
                $tmpFile->close();
                $cmd = "certtool --generate-dh-params --sec-param medium > $tmpFile";
            } else {
                $cmd = 'DH_BITS=2048 mkdhparams';
            }

            my $output = '';
            my $stdRoutine = sub {
                return if $_[0] =~ /^[.+]/;
                chomp( $_[0] );
                step( undef, <<"EOF", 1, 1 );
Generating DH parameter file

$_[0]
EOF
            };

            my $rs = executeNoWait(
                $cmd,
                ( iMSCP::Getopt->noprompt && iMSCP::Getopt->verbose
                    ? undef : $stdRoutine
                ),
                $stdRoutine
            );
            error( $output || 'Unknown error' ) if $rs;
            $rs ||= iMSCP::File->new(
                filename => $tmpFile->filename()
            )->moveFile(
                "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem"
            ) if defined $tmpFile;
            $rs;
        }, 'Generating DH parameter file', 1, 1
    );
    endDetail();
    $rs;
}

=item _buildAuthdaemonrcFile( )

 Build the authdaemonrc file

 Return int 0 on success, other on failure

=cut

sub _buildAuthdaemonrcFile
{
    my ( $self ) = @_;

    my $rs = $self->{'events'}->trigger(
        'onLoadTemplate', 'courier', 'authdaemonrc', \my $cfgTpl, {}
    );
    return $rs if $rs;

    unless ( defined $cfgTpl ) {
        return 1 unless defined(
            $cfgTpl = iMSCP::File->new(
                filename => "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/authdaemonrc"
            )->get()
        );
    }

    $rs = $self->{'events'}->trigger(
        'beforePoBuildAuthdaemonrcFile', \$cfgTpl, 'authdaemonrc'
    );
    return $rs if $rs;

    $cfgTpl =~ s/authmodulelist=".*"/authmodulelist="authmysql"/;

    $rs = $self->{'events'}->trigger(
        'afterPoBuildAuthdaemonrcFile', \$cfgTpl, 'authdaemonrc'
    );
    return $rs if $rs;

    my $file = iMSCP::File->new(
        filename => "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/authdaemonrc"
    );
    $file->set( $cfgTpl );
    $rs = $file->save();
    $rs ||= $file->owner(
        $self->{'config'}->{'AUTHDAEMON_USER'},
        $self->{'config'}->{'AUTHDAEMON_GROUP'}
    );
    $rs ||= $file->mode( 0660 );
}

=item _buildSslConfFiles( )

 Build ssl configuration file

 Return int 0 on success, other on failure

=cut

sub _buildSslConfFiles
{
    my ( $self ) = @_;

    return 0 unless ::setupGetQuestion(
        'SERVICES_SSL_ENABLED', 'no'
    ) eq 'yes';

    for my $conffile ( $self->{'config'}->{'COURIER_IMAP_SSL'},
        $self->{'config'}->{'COURIER_POP_SSL'}
    ) {
        my $rs = $self->{'events'}->trigger(
            'onLoadTemplate', 'courier', $conffile, \my $cfgTpl, {}
        );
        return $rs if $rs;

        unless ( defined $cfgTpl ) {
            return 1 unless defined(
                $cfgTpl = iMSCP::File->new(
                    filename => "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/$conffile"
                )->get()
            );
        }

        $rs = $self->{'events'}->trigger(
            'beforePoBuildSslConfFile', \$cfgTpl, $conffile
        );
        return $rs if $rs;

        if ( $cfgTpl =~ /^TLS_CERTFILE=/gm ) {
            $cfgTpl =~ s!^(TLS_CERTFILE=).*!$1$::imscpConfig{'CONF_DIR'}/imscp_services.pem!gm;
        } else {
            $cfgTpl .= "TLS_CERTFILE=$::imscpConfig{'CONF_DIR'}/imscp_services.pem\n";
        }

        $rs = $self->{'events'}->trigger(
            'afterPoBuildSslConfFile', \$cfgTpl, $conffile
        );
        return $rs if $rs;

        my $file = iMSCP::File->new(
            filename => "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/$conffile"
        );
        $file->set( $cfgTpl );
        $rs = $file->save();
        $rs ||= $file->owner(
            $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'}
        );
        $rs ||= $file->mode( 0644 );
        return $rs if $rs;
    }

    0;
}

=item _migrateFromDovecot( )

 Migrate mailboxes from Dovecot

 Return int 0 on success, other on failure

=cut

sub _migrateFromDovecot
{
    my ( $self ) = @_;

    return 0 unless $::imscpOldConfig{'PO_SERVER'} eq 'dovecot';

    my $rs = $self->{'events'}->trigger( 'beforePoMigrateFromDovecot' );
    return $rs if $rs;

    $rs = execute(
        [
            'perl',
            "$::imscpConfig{'ENGINE_ROOT_DIR'}/PerlVendor/courier-dovecot-migrate.pl",
            '--to-courier', '--quiet', '--convert', '--overwrite', '--recursive',
            $self->{'mta'}->{'config'}->{'MTA_VIRTUAL_MAIL_DIR'}
        ],
        \my $stdout, \my $stderr
    );
    debug( $stdout ) if $stdout;
    error( $stderr || 'Unknown error' ) if $rs;
    return $rs if $rs;

    $self->{'po'}->{'forceMailboxesQuotaRecalc'} = TRUE;
    $::imscpOldConfig{'PO_SERVER'} = 'courier';
    $::imscpOldConfig{'PO_PACKAGE'} = 'Servers::po::courier';
    $self->{'events'}->trigger( 'afterPoMigrateFromDovecot' );
}

=item _oldEngineCompatibility( )

 Remove old files

 Return int 0 on success, other on failure

=cut

sub _oldEngineCompatibility
{
    my ( $self ) = @_;

    if ( -f "$self->{'cfgDir'}/courier.old.data" ) {
        my $rs = iMSCP::File->new(
            filename => "$self->{'cfgDir'}/courier.old.data"
        )->delFile();
        return $rs if $rs;
    }

    if ( -f "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/userdb" ) {
        my $file = iMSCP::File->new(
            filename => "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/userdb"
        );
        $file->set( '' );
        my $rs = $file->save();
        $rs ||= $file->mode( 0600 );

        $rs ||= execute(
            [
                'makeuserdb',
                '-f', "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/userdb"
            ],
            \my $stdout,
            \my $stderr
        );
        debug( $stdout ) if $stdout;
        error( $stderr || 'Unknown error' ) if $rs;
        return $rs if $rs;
    }

    # Remove postfix user from authdaemon group.
    # It is now added in mail group (since 1.5.0)
    my $rs = iMSCP::SystemUser->new()->removeFromGroup(
        $self->{'config'}->{'AUTHDAEMON_GROUP'},
        $self->{'mta'}->{'config'}->{'POSTFIX_USER'}
    );
    return $rs if $rs;

    # Remove old authdaemon socket private/authdaemon mount directory.
    # Replaced by var/run/courier/authdaemon (since 1.5.0)
    my $fsFile = File::Spec->canonpath(
        "$self->{'mta'}->{'config'}->{'POSTFIX_QUEUE_DIR'}/private/authdaemon"
    );
    $rs ||= umount( $fsFile );
    return $rs if $rs;

    local $@;
    eval { iMSCP::Dir->new( dirname => $fsFile )->remove(); };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item _preserveAuthlibMarkers( \$cfgTpl, $dest )

 Keep the ##NAME: markers courier-authlib ships in its configuration files.

 From courier-authlib 0.72, authdaemond refuses a configuration file that has
 lost those markers, logging

   marker line not found in <file> (probably forgot to run sysconftool after
   an upgrade)

 and then rejecting every authentication attempt: the module answers "REJECT -
 try next module", and where authmysql is the only module that means every
 mail login on the server fails. Debian 11 and earlier did not enforce it, so
 replacing the file wholesale was harmless there and is not here.

 i-MSCP builds this file from its own template, which has no markers. Merge the
 generated values into the structure of the file already on disk - the
 packaged one on a first install - and keep a pristine copy, since after the
 first overwrite there is nothing left to learn the structure from.

 Param scalarref \$cfgTpl Generated configuration
 Param string $dest Destination path of the configuration file
 Return int 0 on success, other on failure

=cut

sub _preserveAuthlibMarkers
{
    my ( undef, $cfgTpl, $dest ) = @_;

    return 0 unless defined ${ $cfgTpl };
    return 0 if ${ $cfgTpl } =~ /^##NAME:/m;

    my $pristine = "$dest.imscp-pristine";
    my $base;

    for my $candidate ( $pristine, $dest ) {
        next unless -f $candidate;
        my $content = iMSCP::File->new( filename => $candidate )->get();
        next unless defined $content && $content =~ /^##NAME:/m;
        $base = $content;

        unless ( -f $pristine ) {
            my $file = iMSCP::File->new( filename => $pristine );
            $file->set( $content );
            $file->save() == 0 and $file->mode( 0640 );
            debug( sprintf( 'Kept a marker-bearing copy at %s', $pristine ));
        }
        last;
    }

    unless ( defined $base ) {
        warning( sprintf(
            "No marker-bearing %s to merge into. courier-authlib 0.72+ will "
            . "reject it and every mail login will fail. Reinstall "
            . "courier-authlib-mysql to restore the packaged file, then re-run "
            . "the installer.", $dest
        ));
        return 0;
    }

    my %want;
    for my $line ( split /\n/, ${ $cfgTpl } ) {
        next if $line =~ /^\s*(?:#|$)/;
        my ( $k, $v ) = $line =~ /^(\S+)\s+(.*)$/ or next;
        $want{$k} = $v;
    }

    my ( @out, %seen );
    for my $line ( split /\n/, $base ) {
        if ( my ( $k ) = $line =~ /^(\w+)\s+/ ) {
            if ( exists $want{$k} ) {
                push @out, "$k\t\t$want{$k}";
                $seen{$k} = TRUE;
                next;
            }
        }
        push @out, $line;
    }

    my @missing = grep { !$seen{$_} } sort keys %want;
    if ( @missing ) {
        push @out, '', '# Added by i-MSCP';
        push @out, map { "$_\t\t$want{$_}" } @missing;
    }

    debug( sprintf(
        'Merged %d setting(s) into the packaged %s, %d appended',
        scalar keys %seen, $dest, scalar @missing
    ));

    ${ $cfgTpl } = join( "\n", @out ) . "\n";
    0;
}

=item _installAuthdaemonMountDropIn( \%fields )

 Re-establish the authdaemon bind mount whenever the daemon restarts.

 courier-authdaemon uses RuntimeDirectory=, so systemd removes and recreates
 its socket directory on each restart. The bind mount into the Postfix chroot
 then points at an inode that no longer has a name, the socket disappears from
 the chroot, and SMTP AUTH fails with "unable to canonify user and get
 auxprops" - while mount(8) still reports the mount as present.

 A drop-in that re-binds after the daemon has started closes that window. It is
 conditional on the socket being missing, so a normal start costs nothing.

 Param hashref \%fields Mount fields as passed to mount()
 Return int 0 on success, other on failure

=cut

sub _installAuthdaemonMountDropIn
{
    my ( $self, $fields ) = @_;

    return 0 unless iMSCP::Service->getInstance()->isSystemd();

    my $sname = $self->{'config'}->{'AUTHDAEMON_SNAME'} or return 0;
    my $dir   = "/etc/systemd/system/$sname.service.d";

    local $@;
    eval { iMSCP::Dir->new( dirname => $dir )->make( { mode => 0755 } ); };
    if ( $@ ) { error( $@ ); return 1; }

    my $file = iMSCP::File->new( filename => "$dir/imscp-postfix-chroot.conf" );
    $file->set( <<"EOF" );
# SYSTEMD.UNIT(5) drop-in - auto-generated by i-MSCP
#     DO NOT EDIT THIS FILE BY HAND -- YOUR CHANGES WILL BE OVERWRITTEN
#
# RuntimeDirectory= makes systemd recreate $fields->{'fs_spec'} on every
# restart, which silently detaches the bind mount into the Postfix chroot and
# breaks SMTP authentication. Re-bind once the daemon is up.
[Service]
ExecStartPost=/bin/sh -c '[ -S "$fields->{'fs_file'}/socket" ] || { /bin/umount "$fields->{'fs_file'}" 2>/dev/null; /bin/mount --bind "$fields->{'fs_spec'}" "$fields->{'fs_file'}"; }'
EOF

    my $rs = $file->save();
    $rs ||= $file->mode( 0644 );
    return $rs if $rs;

    my ( $stdout, $stderr );
    $rs = execute(
        [ '/usr/bin/systemctl', 'daemon-reload' ], \$stdout, \$stderr
    );
    debug( $stdout ) if length $stdout;
    error( $stderr || 'Unknown error' ) if $rs;
    $rs;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
