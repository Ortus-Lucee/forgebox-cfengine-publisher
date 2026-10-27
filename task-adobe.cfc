/**
* Publish missing Adobe ColdFusion engines to ForgeBox
*/
component {
	property name='semanticVersion' inject='semanticVersion@semver';

	function run() {
		try {

			// -------------------------------------------------------------------------------
			// The Adobe versions we care about (2023 and 2025)

			print.text( 'Getting Adobe Versions: ' ).toConsole();
			var adobeVersions = getAdobeVersions();
			if( !adobeVersions.len() ) {
				throw( 'Adobe has amnesia and has forgotten all its versions!' );
			}
			print.line( adobeVersions.len() & ' found ( #adobeVersions.first().version# - #adobeVersions.last().version# )' ).toConsole()

			// -------------------------------------------------------------------------------
			// The Adobe versions already on ForgeBox

			print.text( 'Getting ForgeBox Adobe Versions: ' ).toConsole();
			var forgeboxVersions = getForgeBoxVersions();
			print.line( forgeboxVersions.len() & ' found ( #forgeboxVersions.first()# - #forgeboxVersions.last()# )' ).toConsole()

			// -------------------------------------------------------------------------------
			// Anything Adobe has that ForgeBox does not

			var missingVersions = adobeVersions.filter( (v)=>!forgeboxVersions.find( (fv)=>semanticVersion.isEQ( fv, v.version, false ) ) );

			print.line().line( missingVersions.len() & ' missing versions found' ).line().toConsole()
			for( var v in missingVersions ) {
				print.greenLine( 'Processing #v.version# ...' ).toConsole()
				print.line( ' - #v.title# (#v.type#, released #dateFormat( v.pubDate, 'yyyy-mm-dd' )#, #v.daysOld# days old)' ).toConsole();
				print.line( '   #v.techNote#' ).toConsole();
				print.line( '   #v.downloadURL#' ).toConsole();

				slackMessage(
					"Adobe ColdFusion *#v.version#* not found in ForgeBox."
					& chr( 10 ) & "#v.title# (#v.type#) released #dateFormat( v.pubDate, 'yyyy-mm-dd' )#, #v.daysOld# days old."
					& chr( 10 ) & "<#v.techNote#|Release notes>"
				);
				print.line().line().toConsole()
			}

			// Peanut Butter Jelly Time!
			print.greenLine( 'Complete!' );
			print.line().toConsole();

		} catch( any e ) {
			var stackContext = "missing stack";
			if ( ArrayLen( e.tagContext ) gt 0 ) {
				stackContext = e.tagContext[ 1 ].template & ':' &  e.tagContext[ 1 ].line;
			}
			print
				.redLine( e.message )
				.redLine( e.detail )
				.redLine( stackContext )
				.toConsole();

			slackMessage( "Error running the Adobe CF engine publisher. #chr( 10 )# #e.message# #chr( 10 )# #e.detail# #chr( 10 )# #stackContext# " );

			return 1;
		}
	}

	/**
	* The 2023 and 2025 ColdFusion updates from Adobe, as npm style versions
	*/
	array function getAdobeVersions() {
		http url="https://cfdownload.adobe.com/pub/adobe/coldfusion/xml/updates.xml" result="local.updatesRequest";

		// Adobe sends a UTF-8 BOM which chokes the XML parser
		var xmlBody = toString( local.updatesRequest.fileContent );
		if( left( xmlBody, 1 ) == chr( 65279 ) ) {
			xmlBody = xmlBody.right( xmlBody.len() - 1 );
		}

		try {
			var updates = xmlParse( xmlBody );
		} catch( any e ) {
			throw( 'Response from Adobe updates.xml is not XML.' );
		}

		var seen = {};
		var versions = [];
		var itemNodes = xmlSearch( updates, '//item' );
		// Adobe lists the newest updates first
		for( var item in itemNodes ) {
			
			var idParts = xmlValue( xmlSearch( item, './cfhf_id' ) ).listToArray( '-' );
			// Adobe has 2016, 2018 and 2021 updates in here too, we only publish 2023 and 2025
			if( idParts.len() != 4 || idParts[ 1 ] != 'hf' || !listFind( '2023,2025', idParts[ 2 ] ) ) {
				continue;
			}
			// 2025.0.14+332029
			var version = '#idParts[ 2 ]#.0.#numberFormat( int( idParts[ 3 ] ), '00' )#+#idParts[ 4 ]#';
			if( seen.keyExists( version ) ) {
				continue;
			}
			seen[ version ] = true;
			var pubDate = parseAdobePubDate( xmlValue( xmlSearch( item, './pubDate' ) ) );
			versions.append( {
				version : version,
				title : xmlValue( xmlSearch( item, './title' ) ),
				type : xmlValue( xmlSearch( item, './cfhf_type' ) ),
				techNote : xmlValue( xmlSearch( item, './cfhf_technotelink' ) ),
				downloadURL : xmlValue( xmlSearch( item, './cfhf_servers/cfhf_server/cfhf_downloadlink' ) ),
				pubDate : pubDate,
				daysOld : dateDiff( 'd', pubDate, now() )
			} );
		}

		return versions;
	}

	/**
	* The text of the first node matched by an xpath, or an empty string
	*/
	string function xmlValue( required array nodes ) {
		return arguments.nodes.len() ? arguments.nodes[ 1 ].xmlText : '';
	}

	/**
	* Adobe's pubDate is a long date like "Wednesday, October 13, 2026"
	*/
	date function parseAdobePubDate( required string pubDate ) {
		// Drop the weekday name
		var dateParts = arguments.pubDate.listToArray( ' ' );
		if( dateParts.len() > 1 ) {
			dateParts.deleteAt( 1 );
		}
		try {
			return parseDateTime( dateParts.toList( ' ' ) );
		} catch( any e ) {
			return now();
		}
	}

	/**
	* The versions of Adobe already published to ForgeBox
	*/
	array function getForgeBoxVersions() {
		var forgeboxVersions = command( 'forgebox show adobe --json' ).run( returnOutput=true );
		return deserializeJSON( print.unansi( forgeboxVersions ) ).versions.map( (v)=>v.version );
	}

	function slackMessage( required string message ) {
		var payload = serializeJSON( {"text":message} );
		http url=getSystemSetting( 'SLACK_WEBHOOK_URL_ADOBE' ) method="post" result='local.cfhttp' {
			cfhttpparam( type="body", value='#payload#');
		}
		if( local.cfhttp.status_code != '200' ) {
			print.redLine( 'Error Sending Slack message: #local.cfhttp.statuscode# #local.cfhttp.fileContent# ' );
			print.redLine( payload );

		}
	}


}
