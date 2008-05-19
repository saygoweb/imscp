<?php
/**
 * ispCP ω (OMEGA) a Virtual Hosting Control System
 *
 * @copyright 	2001-2006 by moleSoftware GmbH
 * @copyright 	2006-2008 by ispCP | http://isp-control.net
 * @version 	SVN: $ID$
 * @link 		http://isp-control.net
 * @author 		ispCP Team
 *
 * @license
 *   This program is free software; you can redistribute it and/or modify it under
 *   the terms of the MPL General Public License as published by the Free Software
 *   Foundation; either version 1.1 of the License, or (at your option) any later
 *   version.
 *   You should have received a copy of the MPL Mozilla Public License along with
 *   this program; if not, write to the Open Source Initiative (OSI)
 *   http://opensource.org | osi@opensource.org
 */

require '../include/ispcp-lib.php';

check_login(__FILE__);

$tpl = new pTemplate();
$tpl->define_dynamic('page', $cfg['CLIENT_TEMPLATE_PATH'] . '/puser_uadd.tpl');
$tpl->define_dynamic('page_message', 'page');
$tpl->define_dynamic('usr_msg', 'page');
$tpl->define_dynamic('grp_msg', 'page');
$tpl->define_dynamic('logged_from', 'page');
$tpl->define_dynamic('pusres', 'page');
$tpl->define_dynamic('pgroups', 'page');

$theme_color = $cfg['USER_INITIAL_THEME'];

$tpl->assign(
		array(
			'TR_CLIENT_WEBTOOLS_PAGE_TITLE' => tr('ispCP - Client/Webtools'),
			'THEME_COLOR_PATH' => "../themes/$theme_color",
			'THEME_CHARSET' => tr('encoding'),
			'ISP_LOGO' => get_logo($_SESSION['user_id'])
		)
	);

function padd_user(&$tpl, &$sql, &$dmn_id) {
	if (isset($_POST['uaction']) && $_POST['uaction'] == 'add_user') {
		// we have user to add
		if (isset($_POST['username']) && isset($_POST['pass']) && isset($_POST['pass_rep'])) {
			if (!chk_username($_POST['username'])) {
				set_page_message(tr('Wrong username!'));
				return;
			}
			if (!chk_password($_POST['pass'])) {
				set_page_message(tr('Incorrect password length or syntax!'));
				return;
			}
			if ($_POST['pass'] !== $_POST['pass_rep']) {
				set_page_message(tr('Passwords do not match!'));
				return;
			}
			global $cfg;
			$change_status = $cfg['ITEM_ADD_STATUS'];

			$uname = clean_input($_POST['username']);

			if (CRYPT_BLOWFISH == 1) {
				// suhosin enables blowfish, but apache cannot crypt this, so we don't need that
				if (CRYPT_MD5 == 1) { // use md5 if available: salt is $1$.microseconds.$
					$upass = crypt($_POST['pass'], '$1$' . microtime() . '$');
				} else { // else only DES encryption is used
					$upass = crypt($_POST['pass'], microtime());
				}
			} else {
				$upass = crypt($_POST['pass']);
			}

			$query = <<<SQL_QUERY
        select
			id
        from
            htaccess_users
        where
             uname = ?
			 and
			 dmn_id = ?
SQL_QUERY;

			$rs = exec_query($sql, $query, array($uname, $dmn_id));

			if ($rs->RecordCount() == 0) {
				$query = <<<SQL_QUERY

            insert into htaccess_users

               (dmn_id, uname, upass, status)

            values

               (?, ?, ?, ?)

SQL_QUERY;

				$rs = exec_query($sql, $query, array($dmn_id, $uname, $upass, $change_status));

				global $cfg;
				$change_status = $cfg['ITEM_CHANGE_STATUS'];

				$query = <<<SQL_QUERY
                    update
                        htaccess
                    set
                        status = ?
                    where
                         dmn_id = ?
SQL_QUERY;
				$rs = exec_query($sql, $query, array($change_status, $dmn_id));

				check_for_lock_file();
				send_request();

				$admin_login = $_SESSION['user_logged'];
				write_log("$admin_login: add user (protected areas): $uname");
				header('Location: puser_manage.php');
				die();
			} else {
				set_page_message(tr('User already exist !'));
				return;
			}
		}
	} else {
		return;
	}
}

function gen_page_awstats(&$tpl) {
	global $cfg;
	$awstats_act = $cfg['AWSTATS_ACTIVE'];
	if ($awstats_act != 'yes') {
		$tpl->assign('ACTIVE_AWSTATS', '');
	} else {
		$tpl->assign(
			array(
				'AWSTATS_PATH' => 'http://' . $_SESSION['user_logged'] . '/stats/',
				'AWSTATS_TARGET' => '_blank'
				)
			);
	}
}

/*
 *
 * static page messages.
 *
 */

gen_client_mainmenu($tpl, $cfg['CLIENT_TEMPLATE_PATH'] . '/main_menu_webtools.tpl');
gen_client_menu($tpl, $cfg['CLIENT_TEMPLATE_PATH'] . '/menu_webtools.tpl');

gen_logged_from($tpl);

gen_page_awstats($tpl);

check_permissions($tpl);

padd_user($tpl, $sql, get_user_domain_id($sql, $_SESSION['user_id']));

$tpl->assign(
		array(
			'TR_HTACCESS' => tr('Protected areas'),
			'TR_ACTION' => tr('Action'),
			'TR_USER_MANAGE' => tr('Manage user'),
			'TR_USERS' => tr('User'),
			'TR_USERNAME' => tr('Username'),
			'TR_ADD_USER' => tr('Add user'),
			'TR_GROUPNAME' => tr('Group name'),
			'TR_GROUP_MEMBERS' => tr('Group members'),
			'TR_ADD_GROUP' => tr('Add group'),
			'TR_EDIT' => tr('Edit'),
			'TR_GROUP' => tr('Group'),
			'TR_DELETE' => tr('Delete'),
			'TR_GROUPS' => tr('Groups'),
			'TR_PASSWORD' => tr('Password'),
			'TR_PASSWORD_REPEAT' => tr('Repeat password'),
			'TR_CANCEL' => tr('Cancel'),
		)
	);

gen_page_message($tpl);

$tpl->parse('PAGE', 'page');
$tpl->prnt();

if ($cfg['DUMP_GUI_DEBUG'])
	dump_gui_debug();

unset_messages();

?>