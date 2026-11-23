# ForgeBox CF Engine Publisher

A task runner to automate publishing of new CF Engines to [ForgeBox](https://www.forgebox.io/view/lucee#versions)

Rename the `.env-example` file to `.env` add add your S3 credentials and your ForgeBox API key.   Then run the task.

Install dependencies with
 
```
box install
```

Then you can run the task like so:

```
box task run
```

All new Lucee releases that are not published on ForgeBox will be
* Built as a CommandBox engine zip (`box.json` plus `engine.war`) from the official Lucee jar or light jar
* Uploaded to S3
* Published to ForgeBox

Jars are taken from [GitHub Releases](https://github.com/lucee/Lucee/releases) for releases, RCs and alphas, and from [maven.lucee-services.com](https://maven.lucee-services.com/org/lucee/lucee/) for snapshots and as a fallback. The version list still comes from `https://release.lucee.org/rest/update/provider/list?extended=true`. This is done for Lucee and Lucee Light editions.

To build a package locally without publishing it:

```
box task run taskFile=task.cfc target=buildPackage :version=8.0.0.310 :light=true :dest=/tmp/lucee-light-8.0.0.310.zip
```

## Scheduled Workflows

Each scheduled workflow runs one task CFC:

* [release.yml](.github/workflows/release.yml) - daily at midnight UTC, runs `box task run` (`task.cfc`). Builds new Lucee engine packages, uploads them to S3 and publishes them to ForgeBox.
* [adobe.yml](.github/workflows/adobe.yml) - every 2 hours, runs `box task run task-adobe`. Finds Adobe ColdFusion 2023 and 2025 updates that are not on ForgeBox yet and posts a Slack notice for each one.
