/**
* Publish missing Lucee engines to ForgeBox
*/
component {
	property name='semanticVersion' inject='semanticVersion@semver';
	property name="progressableDownloader" inject="ProgressableDownloader";
	property name="progressBar" inject="ProgressBar";

	variables.gitHubReleaseUrl = 'https://github.com/lucee/Lucee/releases/download';
	variables.sonatypeSnapshotsUrl = 'https://central.sonatype.com/repository/maven-snapshots';
	variables.mavenCentralUrl = 'https://repo1.maven.org/maven2';
	// Fallback only. This endpoint will no longer host snapshots in the future, so it must not be the primary source.
	variables.mavenServicesUrl = 'https://maven.lucee-services.com';
	// Jars and the packages built from them should be at least 1MB (enough to reject an error page)
	// and no larger than 250MB.
	variables.minArtifactBytes = 1000 * 1000;
	variables.maxArtifactBytes = 250 * 1000 * 1000;

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
					jar : v.jar ?: '',
					light : v.light ?: ''
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
			.append( luceeVersions.filter( (lv)=>len( lv.jar ) && !forgeboxVersions.findNoCase( lv.version ) && semanticVersion.isNew( minVersion, lv.version ) ).map( (v)=>duplicate(v).append({light:false}) ), true )
			// Add in Lucee Light versions later than minVersion and not in ForgeBox
			.append( luceeVersions.filter( (lv)=>len( lv.light ) && !forgeboxLightVersions.findNoCase( lv.version ) && semanticVersion.isNew( minVersion, lv.version ) ).map( (v)=>duplicate(v).append({light:true}) ), true );

		print.line( missingVersions.len() & ' missing versions found' ).line().line().toConsole()

		// -------------------------------------------------------------------------------

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
				var Ortuss3URI='lucee/lucee/#v.luceeVersion#/cf-engine-#v.luceeVersion##(v.light?'-light':'')#.zip'

				if( !fileExists( localPath ) ) {
					buildEnginePackage(
						luceeVersion = v.luceeVersion,
						semver = v.version,
						light = v.light,
						outputPath = localPath
					);
				}

				var fileSize = getFileInfo( localPath ).size;
				// Ignore tiny files (usually an error page) and unexpectedly huge ones
				if( fileSize < variables.minArtifactBytes ) {
					print.redLine( 'Built file #localPath# too small [#round(fileSize/1000)#K], ignoring.' )
					fileDelete( localPath )
				} else if ( fileSize > variables.maxArtifactBytes ) {
					print.redLine( 'Built file #localPath# was too large [#numberFormat(round(fileSize/1000))#K].' )
					fileDelete( localPath )
				} else {
					print.line( 'Built file #localPath# is [#numberFormat(round(fileSize/1000))#K].' )

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
						// ForgeBox keeps throwing these but we don't know why. When it does, the package is still published just fine so ingore them
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
					stackContext = e.tagContext[ 1 ].template & ':' & e.tagContext[ 1 ].line;
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
		print.line().line( "Updating last run in repo" ).toConsole();
		updateLastRun();
	}

	/**
	 * Build a single engine zip (box.json + engine.war) from the official jar / light jar.
	 * Usage: box task run buildPackage version=8.0.0.310 light=true dest=/tmp/engine.zip
	 */
	function buildPackage( required string version, boolean light=false, string dest='' ) {
		var luceeVersion = arguments.version;
		var semver = luceeVersion.reReplace( '([0-9]*\.[0-9]*\.[0-9]*)(\.)([0-9]*)(-.*)?', '\1\4+\3' );
		var outputPath = len( arguments.dest ) ? arguments.dest : resolvePath( 'download/lucee#( arguments.light ? '-light' : '' )#-#luceeVersion#.zip' );
		directoryCreate( getDirectoryFromPath( outputPath ), true, true );
		buildEnginePackage(
			luceeVersion = luceeVersion,
			semver = semver,
			light = arguments.light,
			outputPath = outputPath
		);
		print.greenLine( 'Wrote #outputPath# ([#numberFormat( round( getFileInfo( outputPath ).size / 1000 ) )#K]).' ).toConsole();
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
			"branch": "master"
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

	/**
	 * Download the official jar, wrap it as engine.war, and zip it with box.json.
	 */
	function buildEnginePackage(
		required string luceeVersion,
		required string semver,
		required boolean light,
		required string outputPath
	) {
		var workDir = getTempDirectory() & 'fb-engine-#arguments.luceeVersion##( arguments.light ? '-light' : '' )#-#createUniqueId()#/';
		directoryCreate( workDir, true, true );
		try {
			var jarPath = workDir & 'lucee.jar';
			downloadLuceeJar( arguments.luceeVersion, arguments.light, jarPath );

			var boxJsonPath = workDir & 'box.json';
			fileWrite( boxJsonPath, engineBoxJson( arguments.luceeVersion, arguments.semver, arguments.light ) );

			var warPath = workDir & 'engine.war';
			createEngineWar( arguments.luceeVersion, arguments.light, jarPath, warPath );

			if ( fileExists( arguments.outputPath ) ) {
				fileDelete( arguments.outputPath );
			}
			directoryCreate( getDirectoryFromPath( arguments.outputPath ), true, true );
			zip action="zip" file="#arguments.outputPath#" overwrite=true {
				zipparam source=boxJsonPath entrypath="box.json";
				zipparam source=warPath entrypath="engine.war";
			}
		} finally {
			if ( directoryExists( workDir ) ) {
				directoryDelete( workDir, true );
			}
		}
	}

	private function downloadLuceeJar( required string version, required boolean light, required string destPath ) {
		var candidates = jarUrlCandidates( arguments.version, arguments.light );
		var lastError = 'No download URL is configured.';
		for ( var candidate in candidates ) {
			try {
				// Do not pre-follow redirects with cfhttp: GitHub's signed asset URLs can fail if they are replayed.
				// ProgressableDownloader follows redirects; the callback keeps the download on allowed hosts.
				assertAllowedDownloadUrl( candidate );
				print.line( 'Downloading #candidate# ...' ).toConsole();
				progressableDownloader.download(
					candidate,
					arguments.destPath,
					( status )=>progressBar.update( argumentCollection = status ),
					( newURL )=>assertAllowedDownloadUrl( newURL )
				);
				assertValidArtifact( arguments.destPath, 'jar' );
				return;
			} catch ( any e ) {
				lastError = e.message;
				print.line( 'Download failed from #candidate#: #e.message#' ).toConsole();
				if ( fileExists( arguments.destPath ) ) {
					fileDelete( arguments.destPath );
				}
			}
		}
		throw( message='Could not download the Lucee#( arguments.light ? ' light' : '' )# jar for #arguments.version#. #lastError#' );
	}

	private array function jarUrlCandidates( required string version, required boolean light ) {
		var urls = [];
		if ( isSnapshot( arguments.version ) ) {
			// Snapshots: Sonatype first. maven.lucee-services.com is only a fallback and will no longer host snapshots in the future.
			var sonatypeUrl = sonatypeSnapshotJarUrl( arguments.version, arguments.light );
			if ( len( sonatypeUrl ) ) {
				arrayAppend( urls, sonatypeUrl );
			}
		} else {
			// Releases, RCs and alphas: GitHub Releases first, then Maven Central (the main jar), then our Maven endpoint.
			arrayAppend( urls, gitHubJarUrl( arguments.version, arguments.light ) );
			arrayAppend( urls, mavenCentralJarUrl( arguments.version, arguments.light ) );
		}
		// Last fallback for every kind of version, including snapshots Sonatype has already dropped.
		arrayAppend( urls, mavenServicesJarUrl( arguments.version, arguments.light ) );
		return urls;
	}

	private string function gitHubJarUrl( required string version, required boolean light ) {
		var tag = reReplaceNoCase( arguments.version, '-(SNAPSHOT|RC|BETA|ALPHA)$', '' );
		var fileName = arguments.light ? 'lucee-light-#arguments.version#.jar' : 'lucee-#arguments.version#.jar';
		return variables.gitHubReleaseUrl & '/' & tag & '/' & fileName;
	}

	private string function mavenCentralJarUrl( required string version, required boolean light ) {
		var fileName = arguments.light ? 'lucee-#arguments.version#-light.jar' : 'lucee-#arguments.version#.jar';
		return variables.mavenCentralUrl & '/org/lucee/lucee/' & arguments.version & '/' & fileName;
	}

	private string function mavenServicesJarUrl( required string version, required boolean light ) {
		var fileName = arguments.light ? 'lucee-#arguments.version#-light.jar' : 'lucee-#arguments.version#.jar';
		return variables.mavenServicesUrl & '/org/lucee/lucee/' & arguments.version & '/' & fileName;
	}

	/**
	 * Resolve the timestamped snapshot jar on Sonatype from maven-metadata.xml.
	 * Returns an empty string when that version is no longer there, so the caller can fall back.
	 */
	private string function sonatypeSnapshotJarUrl( required string version, required boolean light ) {
		var metaUrl = variables.sonatypeSnapshotsUrl & '/org/lucee/lucee/' & arguments.version & '/maven-metadata.xml';
		http url=metaUrl method="GET" result="local.res" timeout="30" throwOnError="false";
		var status = val( local.res.status_code ?: 0 );
		if ( status != 200 || !len( local.res.filecontent ?: '' ) ) {
			print.line( 'Sonatype has no snapshot metadata for #arguments.version# (HTTP #status#).' ).toConsole();
			return '';
		}
		var stamp = snapshotTimestampValue( toString( local.res.filecontent ), arguments.light );
		if ( !len( stamp ) ) {
			print.line( 'Sonatype metadata for #arguments.version# has no #( arguments.light ? 'light ' : '' )#jar.' ).toConsole();
			return '';
		}
		var fileName = arguments.light ? 'lucee-#stamp#-light.jar' : 'lucee-#stamp#.jar';
		return variables.sonatypeSnapshotsUrl & '/org/lucee/lucee/' & arguments.version & '/' & fileName;
	}

	private string function snapshotTimestampValue( required string metadata, required boolean light ) {
		try {
			var doc = xmlParse( arguments.metadata );
			var xpath = arguments.light
				? "/metadata/versioning/snapshotVersions/snapshotVersion[classifier='light' and extension='jar']/value"
				: "/metadata/versioning/snapshotVersions/snapshotVersion[extension='jar' and not(classifier)]/value";
			var nodes = xmlSearch( doc, xpath );
			if ( arrayLen( nodes ) && len( trim( nodes[ 1 ].xmlText ?: '' ) ) ) {
				return trim( nodes[ 1 ].xmlText );
			}
		} catch ( any e ) {
			// Fall through to the regex parse below
		}

		var blocks = reMatchNoCase( '(?s)<snapshotVersion>.*?</snapshotVersion>', arguments.metadata );
		for ( var block in blocks ) {
			if ( !reFindNoCase( '<extension>\s*jar\s*</extension>', block ) ) {
				continue;
			}
			var hasClassifier = reFindNoCase( '<classifier>', block );
			var isLight = reFindNoCase( '<classifier>\s*light\s*</classifier>', block );
			if ( arguments.light ? isLight : !hasClassifier ) {
				var valueMatch = reFindNoCase( '<value>\s*([^<]+?)\s*</value>', block, 1, true );
				if ( arrayLen( valueMatch.pos ) >= 2 && valueMatch.pos[ 2 ] > 0 ) {
					return trim( mid( block, valueMatch.pos[ 2 ], valueMatch.len[ 2 ] ) );
				}
			}
		}
		return '';
	}

	private boolean function isSnapshot( required string version ) {
		return reFindNoCase( '-SNAPSHOT$', arguments.version ) > 0;
	}


	private function assertAllowedDownloadUrl( required string url ) {
		if ( !isAllowedDownloadHost( arguments.url ) ) {
			throw( message='Refusing to download from an unexpected host: #getUrlHost( arguments.url )#' );
		}
	}

	private boolean function isAllowedDownloadHost( required string url ) {
		var host = lCase( getUrlHost( arguments.url ) );
		if ( !len( host ) ) {
			return false;
		}
		if ( host == 'github.com' || host == 'maven.lucee-services.com' || host == 'mvn.lucee-services.com' ) {
			return true;
		}
		if ( host == 'central.sonatype.com' || hostEndsWith( host, '.sonatype.com' ) ) {
			return true;
		}
		if ( host == 'repo1.maven.org' || host == 'repo.maven.apache.org' ) {
			return true;
		}
		// GitHub release assets are served from release-assets.githubusercontent.com and similar hosts
		return hostEndsWith( host, '.githubusercontent.com' );
	}

	private boolean function hostEndsWith( required string host, required string suffix ) {
		return len( arguments.host ) >= len( arguments.suffix ) && right( arguments.host, len( arguments.suffix ) ) == arguments.suffix;
	}

	private string function getUrlHost( required string url ) {
		var match = reFindNoCase( '^https?://([^/]+)', arguments.url, 1, true );
		if ( match.pos[ 1 ] == 0 || arrayLen( match.pos ) < 2 ) {
			return '';
		}
		return mid( arguments.url, match.pos[ 2 ], match.len[ 2 ] );
	}


	private function assertValidArtifact( required string path, required string kind ) {
		if ( !fileExists( arguments.path ) ) {
			throw( message='The downloaded #arguments.kind# is missing.' );
		}
		var fileSize = getFileInfo( arguments.path ).size;
		if ( fileSize < variables.minArtifactBytes ) {
			throw( message='The downloaded #arguments.kind# is too small ([#round(fileSize/1000)#K]).' );
		}
		if ( fileSize > variables.maxArtifactBytes ) {
			throw( message='The downloaded #arguments.kind# is too large ([#numberFormat(round(fileSize/1000))#K]).' );
		}
		var inStream = fileOpen( arguments.path, 'readBinary' );
		try {
			var bytes = fileRead( inStream, 4 );
		} finally {
			fileClose( inStream );
		}
		// PK zip/jar signature (0x50 0x4B)
		if ( !isBinary( bytes ) || len( bytes ) < 2 || bytes[ 1 ] != 80 || bytes[ 2 ] != 75 ) {
			throw( message='The downloaded #arguments.kind# is not a zip/jar ([#fileSize# bytes]).' );
		}
	}

	private string function engineBoxJson( required string luceeVersion, required string semver, required boolean light ) {
		// Match the historic package box.json, including the double space in the non-light name.
		var edition = arguments.light ? 'Light ' : ' ';
		var json = '{'
			& '"name":"Lucee #edition#CF Engine",'
			& '"version":"#arguments.semver#",'
			& '"createPackageDirectory":false,'
			& '"slug":"lucee#( arguments.light ? '-light' : '' )#",'
			& '"shortDescription":"Lucee #edition#WAR engine for CommandBox servers.",'
			& '"type":"cf-engines"';
		if ( versionGTE( arguments.luceeVersion, 7 ) ) {
			json &= ',"JakartaEE":true';
		}
		json &= '}';
		return json;
	}

	private function createEngineWar(
		required string version,
		required boolean light,
		required string jarPath,
		required string warPath
	) {
		var templateRoot = getDirectoryFromPath( getCurrentTemplatePath() ) & 'build/';
		var webXml = templateRoot & warTemplate( arguments.version ) & '/WEB-INF/web.xml';
		var license = templateRoot & 'common/License.txt';
		if ( !fileExists( webXml ) ) {
			throw( message='Missing WAR template: #webXml#' );
		}
		var jarEntry = arguments.light ? 'WEB-INF/lib/lucee-light.jar' : 'WEB-INF/lib/lucee.jar';
		var deployDir = getTempDirectory() & 'fb-deploy-#createUniqueId()#/';
		directoryCreate( deployDir, true, true );
		try {
			zip action="zip" file="#arguments.warPath#" overwrite=true {
				zipparam source=webXml entrypath="WEB-INF/web.xml";
				zipparam source=license entrypath="License.txt";
				zipparam source=arguments.jarPath entrypath="#jarEntry#";
				zipparam source=deployDir prefix="WEB-INF/lucee-server/context/deploy";
			}
		} finally {
			if ( directoryExists( deployDir ) ) {
				directoryDelete( deployDir, true );
			}
		}
	}

	private string function warTemplate( required string version ) {
		if ( versionGTE( arguments.version, 7 ) ) {
			return 'war-7.0';
		}
		if ( versionGTE( arguments.version, 6, 2 ) ) {
			return 'war-6.2';
		}
		return 'war';
	}

	private boolean function versionGTE( required string version, required numeric major, numeric minor=0 ) {
		var parts = listToArray( listFirst( arguments.version, '-' ), '.' );
		var maj = arrayLen( parts ) >= 1 ? val( parts[ 1 ] ) : 0;
		var min = arrayLen( parts ) >= 2 ? val( parts[ 2 ] ) : 0;
		if ( maj > arguments.major ) {
			return true;
		}
		return maj == arguments.major && min >= arguments.minor;
	}

}
