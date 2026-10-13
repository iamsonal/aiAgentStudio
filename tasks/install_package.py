"""Install one of this project's unlocked packages into an org."""

from cumulusci.core.config.util import get_devhub_config
from cumulusci.core.exceptions import CumulusCIException
from cumulusci.salesforce_api.utils import get_simple_salesforce_connection
from cumulusci.tasks.salesforce.install_package_version import InstallPackageVersion


class InstallNewestPackageVersion(InstallPackageVersion):
    """Install the newest version of an unlocked package, beta or released.

    A package without a namespace has no "latest" that CumulusCI can look up,
    so this task asks the Dev Hub for the newest version of the package named
    in sfdx-project.json's packageAliases and installs its 04t.
    Set the version option to a 04t to install that version instead.
    Safe to repeat: CumulusCI skips the install when the org has that version or a newer one.
    """

    task_options = {
        **InstallPackageVersion.task_options,
        "package": {
            "description": "The package's alias in sfdx-project.json, such as AgentCore.",
            "required": True,
        },
        "version": {
            "description": "A 04t to install. Defaults to the package's newest version in the Dev Hub.",
            "required": False,
        },
    }

    def _init_options(self, kwargs):
        super()._init_options(kwargs)
        # The parent names the package after this repo; show the package being installed.
        given = {**(self.task_config.options or {}), **kwargs}
        self.options["name"] = given.get("name") or self.options["package"]

    def _run_task(self):
        if not self.options.get("version"):
            version_id, version_number = self._newest_version()
            self.options["version"] = version_id
            self.options["version_number"] = version_number
        self.logger.info(
            "Installing %s %s (%s).",
            self.options["package"],
            self.options.get("version_number", ""),
            self.options["version"],
        )
        super()._run_task()

    def _newest_version(self):
        package = self.options["package"]
        aliases = self.project_config.sfdx_project_config.get("packageAliases") or {}
        package_id = aliases.get(package)
        if not package_id or not package_id.startswith("0Ho"):
            raise CumulusCIException(
                f"sfdx-project.json has no package ID for {package} under packageAliases. "
                "Run sf package create for it, then add its 0Ho ID."
            )
        tooling = get_simple_salesforce_connection(
            self.project_config,
            get_devhub_config(self.project_config),
            api_version=self.project_config.project__package__api_version,
            base_url="tooling",
        )
        records = tooling.query(
            "SELECT SubscriberPackageVersionId, MajorVersion, MinorVersion, PatchVersion, BuildNumber "
            f"FROM Package2Version WHERE Package2Id = '{package_id}' AND IsDeprecated = false "
            "ORDER BY MajorVersion DESC, MinorVersion DESC, PatchVersion DESC, BuildNumber DESC LIMIT 1"
        )["records"]
        if not records:
            raise CumulusCIException(
                f"{package} has no versions in the Dev Hub. Run cci flow run build_packages first."
            )
        newest = records[0]
        number = (
            f"{newest['MajorVersion']}.{newest['MinorVersion']}."
            f"{newest['PatchVersion']}-{newest['BuildNumber']}"
        )
        return newest["SubscriberPackageVersionId"], number
