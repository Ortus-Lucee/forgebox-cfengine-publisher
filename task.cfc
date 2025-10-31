/**
* Publish missing Lucee engines to ForgeBox
*/
component {
	property name='semanticVersion' inject='semanticVersion@semver';
	property name="progressableDownloader" 	inject="ProgressableDownloader";
	property name="progressBar" 			inject="ProgressBar";

	function run() {
		variables.ortus_lucee_token=getSystemSetting( 'ORTUS_LUCEE_TOKEN' );

		loadModule( 'modules/s3sdk' )
		var s3 = getInstance( name='AmazonS3@S3SDK', initArguments={
			accessKey=getSystemSetting( 'S3_ACCESS_KEY' ),
			secretKey=getSystemSetting( 'S3_SECRET' ),
			defaultBucketName='downloads.ortussolutions.com'
		} );
		command( 'config set' ).params( 'endpoints.forgebox.apitoken'=getSystemSetting( 'FORGEBOX_TOKEN' ) ).flags( 'quiet' ).run();

		// -------------------------------------------------------------------------------

		print.text( 'Getting Lucee Versions: ' ).toConsole();
		// This is every version of Lucee ever published since 5.0.0
		http url="https://release.lucee.org/rest/update/provider/list?extended=true" result="local.luceeVersions";
		if( isJSON( local.luceeVersions.fileContent ) ) {
			local.luceeVersions = deserializeJSON( local.luceeVersions.fileContent ).map( (k,v)=>{
				// Convert 1.2.3.4-foo to 1.2.3-foo+4 (semver)
				return {
					version : v.version.reReplace( '([0-9]*\.[0-9]*\.[0-9]*)(\.)([0-9]*)(-.*)?', '\1\4+\3' ),
					luceeVersion : v.version,
					fb : v.fb ?: '',
					fbl : v.fbl ?: ''
				}
				// These versions don't have jars, so ignore
			} )
			.valueArray()
			.filter( (v)=>!v.version.reFindNoCase( '(5\.3\.1\+91|5\.3\.3\+67|5\.3\.1\+91|5\.3\.3\+67|5\.3\.8\+84)' ) ) // snapshot|rc|beta|alpha
		} else {
			print.line( local.luceeVersions );
			throw( 'Response from Lucee API is not JSON.' );
		}

		if( !local.luceeVersions.len() ) {
			throw( 'Lucee has amnesia and has forgotten all its versions!' );
		}

		print.line( local.luceeVersions.len() & ' found ( #local.luceeVersions.first().version# - #local.luceeVersions.last().version# )' ).toConsole()

		// -------------------------------------------------------------------------------

		print.text( 'Getting ForgeBox Lucee Versions: ' ).toConsole();
		var forgeboxVersions = command( 'forgebox show lucee --json' ).run( returnOutput=true );
		forgeboxVersions = deserializeJSON( print.unansi( forgeboxVersions ) ).versions.map( (v)=>v.version );

		print.line( forgeboxVersions.len() & ' found ( #forgeboxVersions.last()# - #forgeboxVersions.first()# )' ).toConsole()

		// -------------------------------------------------------------------------------

		print.text( 'Getting ForgeBox Lucee LIGHT Versions: ' ).toConsole();
		var forgeboxLightVersions = command( 'forgebox show lucee-light --json' ).run( returnOutput=true );
		forgeboxLightVersions = deserializeJSON( print.unansi( forgeboxLightVersions ) ).versions.map( (v)=>v.version );

		print.line( forgeboxLightVersions.len() & ' found ( #forgeboxLightVersions.last()# - #forgeboxLightVersions.first()# )' ).toConsole()

		// -------------------------------------------------------------------------------

		var minVersion = '5.2.8';
		print.line( 'looking for missing versions starting at #minVersion#' )
		var missingVersions = []
			// Lucee versions later than minVersion and not in ForgeBox
			.append( luceeVersions.filter( (lv)=>len( lv.fb) && !forgeboxVersions.findNoCase( lv.version ) && semanticVersion.isNew( minVersion, lv.version )  ).map( (v)=>duplicate(v).append({light:false}) ), true )
			// Add in Lucee Light versions later than minVersion and not in ForgeBox
			.append( luceeVersions.filter( (lv)=>len( lv.fbl) && !forgeboxLightVersions.findNoCase( lv.version ) && semanticVersion.isNew( minVersion, lv.version )  ).map( (v)=>duplicate(v).append({light:true}) ), true );


		print.line( missingVersions.len() & ' missing versions found' ).line().line().toConsole()
		//print.line( missingVersions ).toConsole()
		//return ;

		// -------------------------------------------------------------------------------

		var CFEngineURL = 'https://cdn.lucee.org/';
		if( directoryExists( resolvePath( 'download' ) ) ) {
			directoryDelete( resolvePath( 'download' ), true )
		}
		directoryCreate( resolvePath( 'download' ), true, true );
		var errors = false;
		// Process each version
		for( var v in missingVersions ) {
			try {
				print.Greenline( 'Processing #v.version##(v.light?' Light':'')# ...' ).toConsole()
				var localPath = resolvePath( 'download/downloaded-#v.version##(v.light?'-light':'')#.zip' )
				var s3URI = v.light ? v.fbl : v.fb;
				var Ortuss3URI='lucee/lucee/#v.luceeVersion#/cf-engine-#v.luceeVersion##(v.light?'-light':'')#.zip'

				// Download CF Engine from Lucee's update server
				if( !fileExists( localPath ) ) {
					var downloadURL = CFEngineURL & s3URI;
					print.line( 'Downloading #downloadURL# ...' ).toConsole()
					progressableDownloader.download(
						downloadURL,
						localPath,
						( status )=>progressBar.update( argumentCollection = status ),
						( newURL )=>{}
					);
				}

				var fileSize = getFileInfo( localPath ).size;
				// Is download larger than 10MB.  Sometimes Lucee will return a "jar not found" JSON response
				if( fileSize < 10*1000*1000 ) {
					print.redLine( 'Downloaded file #localPath# too small [#round(fileSize/1000)#K], ignoring.' )
					fileDelete( localPath )
				} else if ( fileSize > 250*1000*1000 ) {
					// also ignore files larger than 250mb
					print.redLine( 'Downloaded file #localPath# was too large [#numberFormat(round(fileSize/1000))#K].' )
					fileDelete( localPath )
				} else {
					print.redLine( 'Downloaded file #localPath# is [#numberFormat(round(fileSize/1000))#K].' )
					
					// Push file to Ortus S3 bucket
					if(!s3.objectExists( uri=Ortuss3URI ) ) {
						print.line( 'Uploading #Ortuss3URI# ...' ).toConsole()
						var s3Tries = 0;
						try {
							s3.putObject( uri=Ortuss3URI, data=fileReadBinary( localPath ), contentType='application/octet-stream' );
						// Sometimes S3 will reset the connection, so try a couple times before giving up
						} catch( any e ){
							print.line( e.message ).toConsole()
							s3Tries++
							if( s3Tries < 3 ) {
								sleep( 1000 )
								retry;
							}
							rethrow;
						}
					}

					// Seed a temporary box.json file so we can publish this version to ForgeBox
					directoryCreate( resolvePath( 'temp' ), true, true );
					fileWrite( resolvePath( 'temp/box.json' ), '{
					    "name":"Lucee#(v.light?' Light':'')# CF Engine",
					    "version":"#v.version#",
					    "createPackageDirectory":false,
					    "location":"https://downloads.ortussolutions.com/lucee/lucee/#v.luceeVersion#/cf-engine-#v.luceeVersion##(v.light?'-light':'')#.zip",
					    "slug":"lucee#(v.light?'-light':'')#",
					    "shortDescription":"Lucee#(v.light?' Light':'')# WAR engine for CommandBox servers.",
					    "type":"cf-engines"
					}' )

					try {

						print.line( 'Pubishing to ForgeBox...' ).toConsole()
						// Run publish in the same directory as our temp box.json
						command( 'publish' ).inWorkingDirectory( resolvePath( 'temp' ) ).run();
					} catch( any e ){
						// ForgeBox keeps throwing these but we don't know why.  When it does, the package is still published just fine so ingore them
						if( e.detail contains '408' ) {

							print
								.line( e.message )
								.line( e.detail )
								.toConsole()

							slackMessage( e.detail );

						} else {
							rethrow;
						}
					}

					slackMessage( "Lucee #(v.light?' Light':'')# #v.version# published to ForgeBox." );

				}
			} catch( any e ) {
				errors = true;
				var stackContext = "missing stack";
				if ( ArrayLen(e.tagContext) gt 0 ) {
					stackContext = e.tagContext[ 1 ].template & ':' &  e.tagContext[ 1 ].line;
				}
				print
					.redLine( e.message )
					.redLine( e.detail )
					.redLine( stackContext )
					.toConsole();

				slackMessage( "Error publishing Lucee #(v.light?' Light':'')# #v.version#. #chr(10)# #e.message# #chr(10)# #e.detail# #chr(10)# #stackContext# " );
			}
			print.line().line().toConsole()

		}

		if( errors ) {
			print.redLine( 'Errors encountered on one or more versions' ).toConsole();
			return 1;
		} else {
			// Peanut Butter Jelly Time!
			print.greenLine( 'Complete!' );
		}
	}

	function slackMessage( required string message ) {
		var payload = serializeJSON( {"text":message} );
		http url=getSystemSetting( 'SLACK_WEBHOOK_URL' ) method="post" result='local.cfhttp' {
			cfhttpparam( type="body", value='#payload#');
		}
		if( local.cfhttp.status_code != '200' ) {
			print.redLine( 'Error Sending Slack message: #local.cfhttp.statuscode# #local.cfhttp.fileContent# ' );
			print.redLine( payload );

		}
	}

	function updateLastRun() {
		
		var theURL = 'https://api.github.com/repos/Ortus-Lucee/forgebox-cfengine-publisher/contents/lastRun.txt';
		
		// Get existing file SHA
		http url=theURL method="GET" result="local.getResult" throwOnError="false" {
			httpparam type="header" name="Authorization" value="Bearer #ortus_lucee_token#";
			httpparam type="header" name="Accept" value="application/vnd.github+json";
		}
		
		var payload = {
			"message": "Update last run",
			"content": toBase64(now().toString()),
			"branch": "development"
		};
		
		// Add SHA if file exists
		if (local.getResult.status_Code == "200") {
			payload['sha'] = deserializeJSON(local.getResult.fileContent).sha;
		} else {
			print.line( getResult ).toConsole();
		}
		
		http url=theURL method="PUT" result="local.result" {
			httpparam type="header" name="Authorization" value="Bearer #ortus_lucee_token#";
			httpparam type="header" name="Accept" value="application/vnd.github+json";
			httpparam type="body" value="#serializeJSON(payload)#";
		}
	}

}
