/**
* Publish missing Lucee engines to ForgeBox
*/
component {
	property name='semanticVersion' inject='semanticVersion@semver';
	property name="progressableDownloader" 	inject="ProgressableDownloader";
	property name="progressBar" 			inject="ProgressBar";

	function run() {
		
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
		http url="https://release.lucee.org/rest/update/provider/list" result="local.luceeVersions";
		if( isJSON( local.luceeVersions.fileContent ) ) {
			local.luceeVersions = deserializeJSON( local.luceeVersions.fileContent ).map( (v)=>{
				// Convert 1.2.3.4-foo to 1.2.3-foo+4 (semver)
				return { version:v.version.reReplace( '([0-9]*\.[0-9]*\.[0-9]*)(\.)([0-9]*)(-.*)?', '\1\4+\3' ), luceeVersion:v.version }
				// These versions don't have jars, so ignore
			} ).filter( (v)=>!v.version.reFindNoCase( '(5\.3\.1\+91|5\.3\.3\+67|5\.3\.1\+91|5\.3\.3\+67)' ) ) // snapshot|rc|beta|alpha
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
			.append( luceeVersions.filter( (lv)=>!forgeboxVersions.findNoCase( lv.version ) && semanticVersion.isNew( minVersion, lv.version )  ).map( (v)=>duplicate(v).append({light:false}) ), true )
			// Add in Lucee Light versions later than minVersion and not in ForgeBox
			.append( luceeVersions.filter( (lv)=>!forgeboxLightVersions.findNoCase( lv.version ) && semanticVersion.isNew( minVersion, lv.version )  ).map( (v)=>duplicate(v).append({light:true}) ), true );
		
		
		print.line( missingVersions.len() & ' missing versions found' ).line().line().toConsole()
		//print.line( missingVersions ).toConsole()
		//return ;
				
		// -------------------------------------------------------------------------------
		
		var CFEngineURL = 'http:/'&'/update.lucee.org/rest/update/provider/forgebox/';
		if( directoryExists( resolvePath( 'download' ) ) ) {
			directoryDelete( resolvePath( 'download' ), true )
		}
		directoryCreate( resolvePath( 'download' ), true, true );
		// Process each version
		missingVersions.each( (v)=>{
			print.Greenline( 'Processing #v.version##(v.light?' Light':'')# ...' ).toConsole()
			var localPath = resolvePath( 'download/downloaded-#v.version##(v.light?'-light':'')#.zip' )
			var s3URI='lucee/lucee/#v.luceeVersion#/cf-engine-#v.luceeVersion##(v.light?'-light':'')#.zip'
			
			// Download CF Engine from Lucee's update server
			if( !fileExists( localPath ) ) {
				var downloadURL = CFEngineURL & v.luceeVersion & (v.light?'?light=true':'');
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
			} else {
				
				// Push file to Ortus S3 bucket
				if(!s3.objectExists( uri=s3URI ) ) {
					print.line( 'Uploading #s3URI# ...' ).toConsole()
					var s3Tries = 0;
					try {
						s3.putObject( uri=s3URI, data=fileReadBinary( localPath ), contentType='application/octet-stream' );
					// Sometimes S3 will reset the connection, so try a couple times before giving up
					} catch( any e ){
						print.line( e.message ).toConsole()
						s3Tries++
						if( s3Tries < 3 ) {
							sleep( 1000 )
							retry;
						}
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
				
				print.line( 'Pubishing to ForgeBox...' ).toConsole()
				// Run publish in the same directory as our temp box.json		
				command( 'publish' ).inWorkingDirectory( resolvePath( 'temp' ) ).run();
				
			}
			
			print.line().line().toConsole()	
						
		} );
		
		// Peanut Butter Jelly Time!
		print.greenLine( 'Complete!' );
	}

}
