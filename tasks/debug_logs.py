"""Turn on Apex debug logs for the users a dev org's agents run as."""

from datetime import datetime, timedelta, timezone

from cumulusci.core.exceptions import CumulusCIException
from cumulusci.tasks.salesforce import BaseSalesforceApiTask

# The debug level the Developer Console creates the first time it opens.
DEBUG_LEVEL_NAME = "SFDC_DevConsole"
SERVICE_USER_FILTER = "FirstName = 'Agent Kernel' AND LastName = 'Service Principal'"
AUTOMATED_USER_FILTER = "UserType = 'AutomatedProcess'"


class EnableDebugLogs(BaseSalesforceApiTask):
    """Create or extend a USER_DEBUG trace flag for the admin, service, and Automated Process users.

    Safe to repeat: an existing trace flag is extended instead of duplicated.
    A user that does not exist yet is skipped with a warning.
    Uses the existing SFDC_DevConsole debug level and never creates or changes one.
    """

    task_options = {
        "hours": {
            "description": "How long the logs stay on. Salesforce allows at most 24. Defaults to 24.",
            "required": False,
        },
    }

    def _init_options(self, kwargs):
        super()._init_options(kwargs)
        self.options["hours"] = min(int(self.options.get("hours") or 24), 24)

    def _run_task(self):
        debug_level_id = self._debug_level_id()
        start = datetime.now(timezone.utc)
        expiration = start + timedelta(hours=self.options["hours"])
        users = {
            "admin user": self.org_config.user_id,
            "service user": self._user_id(SERVICE_USER_FILTER),
            "Automated Process user": self._user_id(AUTOMATED_USER_FILTER),
        }
        for label, user_id in users.items():
            if not user_id:
                self.logger.warning("Skipping the %s: no such user in this org.", label)
                continue
            self._upsert_trace_flag(user_id, debug_level_id, start, expiration)
            self.logger.info(
                "Debug logs on for the %s (%s) until %s UTC.",
                label,
                user_id,
                expiration.strftime("%Y-%m-%d %H:%M"),
            )

    def _user_id(self, where):
        records = self.sf.query(f"SELECT Id FROM User WHERE {where} LIMIT 1")["records"]
        return records[0]["Id"] if records else None

    def _debug_level_id(self):
        records = self.tooling.query(
            f"SELECT Id FROM DebugLevel WHERE DeveloperName = '{DEBUG_LEVEL_NAME}'"
        )["records"]
        if not records:
            raise CumulusCIException(
                f"This org has no {DEBUG_LEVEL_NAME} debug level. Open the Developer Console "
                "once to create it, then run enable_debug_logs again."
            )
        return records[0]["Id"]

    def _upsert_trace_flag(self, user_id, debug_level_id, start, expiration):
        # Salesforce rejects a second trace flag whose time range overlaps one
        # the user already has, so extend that one instead.
        records = self.tooling.query(
            "SELECT Id FROM TraceFlag "
            f"WHERE TracedEntityId = '{user_id}' AND LogType = 'USER_DEBUG'"
        )["records"]
        body = {
            "DebugLevelId": debug_level_id,
            "StartDate": _format(start),
            "ExpirationDate": _format(expiration),
        }
        if records:
            self._save("TraceFlag", body, records[0]["Id"])
        else:
            self._save("TraceFlag", {**body, "TracedEntityId": user_id, "LogType": "USER_DEBUG"})

    def _save(self, sobject, body, record_id=None):
        url = f"{self.tooling.base_url}sobjects/{sobject}/"
        if record_id:
            self.tooling._call_salesforce("PATCH", url + record_id, json=body)
            return record_id
        return self.tooling._call_salesforce("POST", url, json=body).json()["id"]


def _format(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%S.000+0000")
