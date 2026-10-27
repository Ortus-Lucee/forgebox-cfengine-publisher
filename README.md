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
* Downloaded from the Lucee update server
* Uploaded to S3
* Published to ForgeBox

This is done for Lucee and Lucee Light editions.

## Scheduled Workflows

Each scheduled workflow runs one task CFC:

* [release.yml](.github/workflows/release.yml) - daily at midnight UTC, runs `box task run` (`task.cfc`). Downloads new Lucee releases, uploads them to S3 and publishes them to ForgeBox.
* [adobe.yml](.github/workflows/adobe.yml) - every 2 hours, runs `box task run task-adobe`. Finds Adobe ColdFusion 2023 and 2025 updates that are not on ForgeBox yet and posts a Slack notice for each one.
