<!-- BDP: user_statistics_entries_block -->
<script>
    $(function () {
        $('.datatable').dataTable({
            language: imscp_i18n.core.dataTable,
            stateSave: {DT_STATE_SAVE},
            order: {DT_ORDER},
            pagingType: "simple"
        });
    });
</script>
<!-- BDP: disk_usage_summary_block -->
<div class="warning">{DISK_USAGE_SUMMARY}</div>
<!-- EDP: disk_usage_summary_block -->
<p>
    <a href="user_statistics.php">{TR_FILTER_ALL}</a> |
    <a href="user_statistics.php?filter=disk">{TR_FILTER_DISK}</a>
</p>
<table class="datatable">
    <thead>
    <tr>
        <th>{TR_USER}</th>
        <th>{TR_DISK}</th>
        <th>{TR_TRAFF}</th>
        <th>{TR_WEB}</th>
        <th>{TR_FTP_TRAFF}</th>
        <th>{TR_SMTP}</th>
        <th>{TR_POP3}</th>
        <th>{TR_SUBDOMAIN}</th>
        <th>{TR_ALIAS}</th>
        <th>{TR_MAIL}</th>
        <th>{TR_FTP}</th>
        <th>{TR_SQL_DB}</th>
        <th>{TR_SQL_USER}</th>
    </tr>
    </thead>
    <tfoot>
    <tr>
        <td>{TR_USER}</td>
        <td>{TR_DISK}</td>
        <td>{TR_TRAFF}</td>
        <td>{TR_WEB}</td>
        <td>{TR_FTP_TRAFF}</td>
        <td>{TR_SMTP}</td>
        <td>{TR_POP3}</td>
        <td>{TR_SUBDOMAIN}</td>
        <td>{TR_ALIAS}</td>
        <td>{TR_MAIL}</td>
        <td>{TR_FTP}</td>
        <td>{TR_SQL_DB}</td>
        <td>{TR_SQL_USER}</td>
    </tr>
    </tfoot>
    <tbody>
    <!-- BDP: user_statistics_entry_block -->
    <tr>
        <td>
            <a href="user_statistics_details.php?user_id={USER_ID}" class="icon i_domain_icon" title="{TR_USER_TOOLTIP}">{USERNAME}</a>
        </td>
        <td data-order="{DISK_SORT}">
            <div class="graph">
                <span style="width:{DISK_PERCENT_WIDTH}%"></span>
                <strong>{DISK_PERCENT}%</strong>
            </div>
            {DISK_MSG}
            <br><strong class="{DISK_STATE_CLASS}">{DISK_STATE}</strong>
        </td>
        <td>
            <div class="graph">
                <span style="width:{TRAFFIC_PERCENT_WIDTH}%"></span>
                <strong>{TRAFFIC_PERCENT}%</strong>
            </div>
            {TRAFFIC_MSG}
        </td>
        <td>{WEB}</td>
        <td>{FTP}</td>
        <td>{SMTP}</td>
        <td>{POP3}</td>
        <td>{SUB_MSG}</td>
        <td>{ALS_MSG}</td>
        <td>{MAIL_MSG}</td>
        <td>{FTP_MSG}</td>
        <td>{SQL_DB_MSG}</td>
        <td>{SQL_USER_MSG}</td>
    </tr>
    <!-- EDP: user_statistics_entry_block -->
    </tbody>
</table>
<!-- EDP: user_statistics_entries_block -->
