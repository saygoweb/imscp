#!/usr/bin/env bash
#
# Functional service tests, from the outside.
#
# 60-verify.sh checks the new box's internal state - files, rows, units.
# This one checks that the services actually answer correctly over the network:
# TLS on every mail and web port, the SMTP capability set the Postfix listener
# is supposed to produce, real sites rendering, and optionally a full mail
# roundtrip through the migrated maildir.
#
#   ./70-test-services.sh --target 10.0.0.5      # test the new box pre-cutover
#   ./70-test-services.sh                        # test whatever DNS resolves to
#   ./70-test-services.sh --target 10.0.0.5 --roundtrip
#   ./70-test-services.sh --baseline             # record aws1 now, to compare against
#
# --target is the important one. Before the Elastic IP moves, DNS still points
# at aws1, so without it every check below passes by testing the OLD box.
#
# Read-only, except that --roundtrip sends one email to the test mailbox.
#
cd "$(dirname "$0")" && . ./lib.sh

MAIL_HOST="${MAIL_HOST:-mail.saygoweb.com}"
PANEL_HOST="${PANEL_HOST:-my.saygoweb.com}"
PANEL_PORT="${PANEL_PORT:-8443}"
WEB_PLAIN="${WEB_PLAIN:-arketec.com}"          # site with no WordPress
WEB_PHP="${WEB_PHP:-elijahshort.co.nz}"        # WordPress, proves PHP-FPM
WEB_MAIN="${WEB_MAIN:-saygoweb.com}"
TEST_MAILBOX="${TEST_MAILBOX:-test@inthefish.com}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-21}"

TARGET=""; ROUNDTRIP=0; BASELINE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --target)    TARGET="$2"; shift 2 ;;
        --roundtrip) ROUNDTRIP=1; shift ;;
        --baseline)  BASELINE=1; shift ;;
        -h|--help)   sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "unknown argument: $1" ;;
    esac
done

FAILED=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# connect_host <hostname> -> the address openssl/curl should actually dial
connect_addr() { [ -n "$TARGET" ] && printf '%s' "$TARGET" || printf '%s' "$1"; }
resolve_opt()  { [ -n "$TARGET" ] && printf -- '--resolve %s:%s:%s' "$1" "$2" "$TARGET"; }

if [ -n "$TARGET" ]; then
    log "Testing $TARGET directly; SNI and Host headers still say the real names"
else
    warn "No --target given: this tests whatever DNS resolves to."
    warn "Before cutover that is still aws1, not the new box."
fi
[ "$BASELINE" = "1" ] && note "baseline mode - recording current behaviour, not asserting migration"

# ---------------------------------------------------------------------------
# TLS endpoints
# ---------------------------------------------------------------------------
# tls_check <label> <hostname> <port> [starttls-proto]
tls_check() {
    local label="$1" host="$2" port="$3" proto="${4:-}"
    local addr; addr=$(connect_addr "$host")
    local out="$TMP/tls-$host-$port.txt"
    local args=( -connect "$addr:$port" -servername "$host" -verify_return_error )
    [ -n "$proto" ] && args+=( -starttls "$proto" )

    if ! printf 'QUIT\r\n' | timeout 20 openssl s_client "${args[@]}" >"$out" 2>&1; then
        # A verify failure still produces a usable handshake dump; separate the
        # two so an expired-but-serving port is not reported as "unreachable".
        if grep -q 'CONNECTED' "$out"; then
            bad "$label ($host:$port) TLS established but certificate did NOT verify"
            # `|| true`: a non-matching grep under `set -e` would abort the
            # whole run at the first failing endpoint, hiding every check after
            # it - which is precisely when you most want the rest.
            grep -m1 'verify error' "$out" | sed 's/^/        /' || true
        else
            bad "$label ($host:$port) no TLS - $(head -1 "$out")"
            return
        fi
    else
        ok "$label ($host:$port) TLS ok"
    fi

    # Every one of these may legitimately find nothing - an endpoint that
    # served no certificate, or one that failed to verify. Under `set -e` a
    # failed command substitution ends the script, so each is guarded: one bad
    # endpoint must not hide the twenty checks that follow it.
    local subject expiry days san pem
    pem=$(sed -n '/BEGIN CERT/,/END CERT/p' "$out" 2>/dev/null || true)
    if [ -z "$pem" ]; then
        note "  no certificate presented"
        return
    fi
    subject=$(printf '%s\n' "$pem" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//' || true)
    expiry=$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    san=$(printf '%s\n' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' ' | tr ',' '\n' | grep -c "DNS:$host\$" || true)

    if [ -n "$expiry" ]; then
        days=$(( ( $(date -d "$expiry" +%s) - $(date +%s) ) / 86400 ))
        if [ "$days" -lt 0 ]; then       bad "  certificate EXPIRED ${days#-} days ago ($expiry)"
        elif [ "$days" -lt "$CERT_WARN_DAYS" ]; then warn "  certificate expires in $days days ($expiry)"
        else                             note "  cert ok for $days days · ${subject:-?}"
        fi
    fi
    [ "${san:-0}" -ge 1 ] && note "  SAN covers $host" \
                          || bad "  certificate does NOT list $host in its SAN"
}

log "TLS endpoints"
tls_check "SMTP"       "$MAIL_HOST" 25  smtp
tls_check "Submission" "$MAIL_HOST" 587 smtp
tls_check "SMTPS"      "$MAIL_HOST" 465
tls_check "IMAPS"      "$MAIL_HOST" 993
tls_check "POP3S"      "$MAIL_HOST" 995
tls_check "HTTPS mail" "$MAIL_HOST" 443
tls_check "HTTPS main" "$WEB_MAIN"  443
tls_check "Panel"      "$PANEL_HOST" "$PANEL_PORT"

# ---------------------------------------------------------------------------
# SMTP capabilities - a direct regression test of the Postfix listener
# ---------------------------------------------------------------------------
# aws1 sets smtpd_sasl_auth_enable = no globally and turns SASL on only for
# submission and smtps via master.cf. The Courier installer sets it to yes, and
# the listener overrides it back at priority -99. If that ordering ever breaks,
# port 25 starts advertising AUTH - which is exactly what this catches.
ehlo_caps() {
    local host="$1" port="$2" proto="${3:-}" addr; addr=$(connect_addr "$host")
    local args=( -connect "$addr:$port" -servername "$host" -quiet )
    [ -n "$proto" ] && args+=( -starttls "$proto" )
    # Pace the commands. Postfix 3.9 added smtpd_forbid_unauth_pipelining and
    # 3.10 turns it on by default, so writing EHLO and QUIT in one go earns a
    # "554 5.5.0 Error: SMTP protocol synchronization" and no capability list
    # at all. aws1's Postfix 3.4 accepted it, which is exactly the kind of
    # difference this script exists to catch - but in the client, not the
    # server.
    { printf 'EHLO migration-test\r\n'; sleep 2; printf 'QUIT\r\n'; sleep 1; } \
        | timeout 25 openssl s_client "${args[@]}" 2>/dev/null
}

log "SMTP capabilities after TLS"
caps25=$(ehlo_caps "$MAIL_HOST" 25 smtp || true)
if [ -z "$caps25" ]; then bad "port 25 gave no EHLO response"
elif grep -qi '^250[- ]AUTH' <<<"$caps25"; then
    bad "port 25 advertises AUTH - the listener's smtpd_sasl_auth_enable=no did not apply"
else
    ok "port 25 does not advertise AUTH (correct)"
fi

for p in 587 465; do
    proto=""; [ "$p" = "587" ] && proto="smtp"
    caps=$(ehlo_caps "$MAIL_HOST" "$p" "$proto" || true)
    if [ -z "$caps" ]; then bad "port $p gave no EHLO response"
    elif grep -qi '^250[- ]AUTH' <<<"$caps"; then
        ok "port $p advertises AUTH ($(grep -i '^250[- ]AUTH' <<<"$caps" | head -1 | tr -d '\r' | cut -c9-))"
    else
        bad "port $p does NOT advertise AUTH - mail clients cannot send"
    fi
done

# ---------------------------------------------------------------------------
# POP / IMAP greetings
# ---------------------------------------------------------------------------
log "POP3 and IMAP greetings"
greet() {
    local host="$1" port="$2" addr; addr=$(connect_addr "$host")
    { sleep 1; printf 'a LOGOUT\r\n'; sleep 1; } \
        | timeout 20 openssl s_client -connect "$addr:$port" \
          -servername "$host" -quiet 2>/dev/null | head -1 | tr -d '\r' || true
}
g=$(greet "$MAIL_HOST" 993); case "$g" in \*\ OK*) ok "IMAP: $g" ;; *) bad "IMAP greeting unexpected: ${g:-none}" ;; esac
g=$(greet "$MAIL_HOST" 995); case "$g" in +OK*)   ok "POP3: $g" ;; *) bad "POP3 greeting unexpected: ${g:-none}" ;; esac

# ---------------------------------------------------------------------------
# Web
# ---------------------------------------------------------------------------
# http_check <label> <host> <expect-wordpress: yes|no> [expected-status]
#
# Two complications this has to be honest about:
#
#  - Cloudflare. saygoweb.com is proxied, so without --target a request never
#    reaches Apache at all: Cloudflare answers, and a managed challenge comes
#    back as 403. Reporting that as a failed site would be wrong, and reporting
#    it as a pass would be worse. It is detected and called out instead.
#  - Baseline runs record what is true today rather than asserting what should
#    be true after the migration, so a status mismatch is a note, not a failure.
http_check() {
    local label="$1" host="$2" wp="$3" want="${4:-200}"
    local body="$TMP/http-$host.html" hdr="$TMP/hdr-$host.txt"
    local code cf=0
    # shellcheck disable=SC2046
    code=$(timeout 30 curl -sS -o "$body" -D "$hdr" -w '%{http_code}' \
             --max-time 25 $(resolve_opt "$host" 443) "https://$host/" 2>"$TMP/curlerr" || echo 000)

    if [ "$code" = "000" ]; then
        bad "$label https://$host unreachable: $(head -1 "$TMP/curlerr")"
        return
    fi

    grep -qiE '^(cf-ray:|server: *cloudflare)' "$hdr" && cf=1

    if [ "$cf" = "1" ] && [ -z "$TARGET" ]; then
        warn "$label https://$host -> $code from Cloudflare, NOT from the server"
        note "  this domain is proxied; only --target reaches the origin"
        note "  nothing below this line would say anything about the migration, so it is skipped"
        return
    fi

    if [ "$code" = "$want" ]; then
        ok "$label https://$host -> $code ($(wc -c <"$body") bytes)"
    elif [ "$BASELINE" = "1" ]; then
        note "$label https://$host -> $code (recorded; expected $want)"
    else
        case "$code" in
            30[12378]) ok "$label https://$host -> $code -> $(grep -i '^location:' "$hdr" | head -1 | tr -d '\r' | cut -d' ' -f2-)" ;;
            *) bad "$label https://$host -> $code, expected $want" ;;
        esac
    fi

    grep -qi '^server:' "$hdr" && note "  served by $(grep -i '^server:' "$hdr" | head -1 | tr -d '\r' | cut -d' ' -f2-)"

    # WordPress leaves unmistakable markers in rendered output. Their presence
    # proves PHP-FPM ran, not merely that Apache returned a file.
    if grep -qiE 'wp-content|wp-includes|wp-json' "$body"; then
        if [ "$wp" = "yes" ]; then ok "  WordPress markers present - PHP-FPM rendered the page"
        else bad "  WordPress markers on a site that should not have them"; fi
    else
        if [ "$wp" = "yes" ]; then bad "  no WordPress markers - PHP probably did not run"
        else ok "  no WordPress markers (as expected)"; fi
    fi
}

log "Web"
http_check "Static site" "$WEB_PLAIN" no
http_check "WordPress"   "$WEB_PHP"   yes
http_check "Main site"   "$WEB_MAIN"  no  "${WEB_MAIN_EXPECT:-200}"

code=$(timeout 30 curl -sS -o /dev/null -w '%{http_code}' --max-time 25 \
        $(resolve_opt "$PANEL_HOST" "$PANEL_PORT") \
        "https://$PANEL_HOST:$PANEL_PORT/" 2>/dev/null || echo 000)
case "$code" in
    200|30[12378]) ok "Panel https://$PANEL_HOST:$PANEL_PORT -> $code" ;;
    *) bad "Panel https://$PANEL_HOST:$PANEL_PORT -> $code" ;;
esac

# ---------------------------------------------------------------------------
# Mail roundtrip
# ---------------------------------------------------------------------------
if [ "$ROUNDTRIP" = "1" ]; then
    log "Mail roundtrip through $TEST_MAILBOX"
    pass="${TEST_MAIL_PASS:-}"
    if [ -z "$pass" ]; then
        if [ -t 0 ]; then
            printf '%s[?]%s password for %s: ' "$YLW" "$RST" "$TEST_MAILBOX"
            read -rs pass; echo
        else
            die "set TEST_MAIL_PASS, or run interactively so it can be prompted for"
        fi
    fi
    [ -n "$pass" ] || die "no password given"

    token="migration-test-$(date +%s)-$RANDOM"
    addr=$(connect_addr "$MAIL_HOST")

    cat > "$TMP/msg.txt" <<MSG
From: $TEST_MAILBOX
To: $TEST_MAILBOX
Subject: $token
Date: $(date -R)

Sent by 70-test-services.sh to prove submission, delivery into the migrated
maildir, and IMAP retrieval all work. Safe to delete.
MSG

    # Credentials go in via --config on stdin so they never appear in ps(1).
    curl_auth() { printf 'user = "%s:%s"\n' "$TEST_MAILBOX" "$pass"; }

    if curl_auth | timeout 60 curl -sS --config - \
            --url "smtp://$addr:587" --ssl-reqd \
            --mail-from "$TEST_MAILBOX" --mail-rcpt "$TEST_MAILBOX" \
            --upload-file "$TMP/msg.txt" >"$TMP/send.log" 2>&1
    then
        ok "submitted via 587 with STARTTLS and AUTH"
    else
        bad "submission failed: $(tail -1 "$TMP/send.log")"
        pass=""; ROUNDTRIP=0
    fi

    if [ "$ROUNDTRIP" = "1" ]; then
        found=0
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            sleep 3
            if curl_auth | timeout 30 curl -sS --config - \
                    --url "imaps://$addr/INBOX?SUBJECT%20$token" \
                    2>/dev/null | grep -q '[0-9]'; then
                ok "delivered and visible over IMAP after $((attempt*3))s"
                found=1; break
            fi
        done
        [ "$found" = "1" ] || bad "message never appeared in INBOX (waited 30s) - check the mail log and the maildir"
        note "test message subject: $token"
    fi
else
    note "mail roundtrip skipped - add --roundtrip (needs the $TEST_MAILBOX password)"
fi

echo
if [ "${FAILED:-0}" -eq 0 ]; then
    log "All service checks passed."
else
    die "${FAILED} check(s) failed"
fi
