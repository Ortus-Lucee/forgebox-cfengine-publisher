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
