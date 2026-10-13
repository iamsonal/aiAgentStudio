"""Conditional metadata deployment tasks for this project."""

from cumulusci.tasks.salesforce.Deploy import Deploy


class DeployIfApexClassMissing(Deploy):
    """Deploy metadata only when the named Apex class is absent from the org."""

    task_options = {
        **Deploy.task_options,
        "apex_class_name": {
            "description": "Apex class name whose presence skips this deployment",
            "required": True,
        },
    }

    def _run_task(self):
        class_name = self.options["apex_class_name"].replace("'", "\\'")
        result = self.org_config.salesforce_client.restful(
            "tooling/query",
            params={
                "q": f"SELECT Id FROM ApexClass WHERE Name = '{class_name}' LIMIT 1"
            },
        )
        if result["totalSize"] > 0:
            self.logger.info(
                "Skipping deployment because Apex class %s already exists.",
                self.options["apex_class_name"],
            )
            return
        self.logger.info(
            "Deploying because Apex class %s does not exist.",
            self.options["apex_class_name"],
        )
        return super()._run_task()
