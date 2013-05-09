<?php

#get common constants and functions from here:
include("trcommon.php");

#error code to print in case of errors
$ERROR_CODE = "-1";

#backup functionality: if there's no POST request, show a simple HTML form for submitting files;
#works only for the human-readable version
if ($_POST) {
	processTranslationRequest();
}
else {
	displayDemoTranslationForm();
}

#####
#
#####
function processTranslationRequest() {
	global $forHumans, $ERROR_CODE;
	
	if (isset($_POST['trText'])) {
		doTranslation(false);
	}
	else if ($_FILES and $_FILES['trFile']['name']) {
		doTranslation($_FILES['trFile']);
	}
	else if ($forHumans) {
		print "<p>Error handling request: neither trText parameter nor file parameter given</p>";
	}
	else {
		print $ERROR_CODE;
	}
}

#####
# function to process the POST request in asynchronous translation mode -- starts the translation job
# and registers a new ID in the database; prints the final response
#####
function doTranslation($fileInfo) {
	global $forHumans, $ERROR_CODE;
	
	$syncMode = !$fileInfo;
	
	$filename = ($syncMode? null: $fileInfo['name']);
	
	#create a DB connection
	$db = initDb($ERROR_CODE);
	
	$langPair = $_POST['langpair'];
	
	#start the background translation job
	$jobId = prepareJobPath($db, $filename);
	
	if ($syncMode) {
		saveText($_POST['trText'], $jobId);
	}
	else {
		moveAsyncFile($fileInfo, $jobId);
	}
	
	startTranslation($langPair, $jobId, $filename, $syncMode);
	
	if ($syncMode) {
		reportSyncResults($jobId);
	}
	else {
		reportAsyncResults($jobId, $filename);
	}
}

#####
#
#####
function saveText($text, $jobId) {
	global $workDir, $ERROR_CODE;
	$path = "$workDir/$jobId/input.txt";
	file_put_contents($path, "$text\n");
}

#####
#
#####
function reportSyncResults($jobId) {
	global $workDir, $ERROR_CODE, $forHumans;
	$path = "$workDir/$jobId/output.txt";
	$translation = file_get_contents($path);
	if ($translation === FALSE) {
		if ($forHumans) {
			print "<p>Failed to translate</p>";
		}
		else {
			print $ERROR_CODE;
		}
	}
	else {
		print "<pre>0\n$translation</pre>";
	}
}

#####
#
#####
function getNewId($db, $filename, $isdone = 0) {
	global $forHumans, $ERROR_CODE;
	
	#create a statement for registering a new job ID in the database;
	#entry initiated with a FALSE (0) value for the "is_done" field
	$stmt = $db->prepare("insert into trids(is_done, filename) values(?, ?)") or die($forHumans? "Failed to prepare statement": $ERROR_CODE);
	$stmt->execute(array($isdone, $filename)) or die($forHumans? "Failed to get ID": $ERROR_CODE);
	
	#get the inserted ID
	$result = $db->lastInsertId();
	
	#check if successful
	if (!$result) {
		die($forHumans? "Failed to retrieve last-insert-ID": $ERROR_CODE);
	}
	
	return $result;
}

#####
#
#####
function prepareJobPath($db, $origFileName) {
	global $workDir, $ERROR_CODE;
	
	#get the new job ID via DB
	$jobId = getNewId($db, $origFileName);

	#save the job ID, if successfully registered
	if (!$jobId) {
		if ($forHumans) {
			print "<p>Error processing " . $filename . "</p>";
		}
		else {
			print $ERROR_CODE;
		}
		die;
	}
	
	$jobPath = "$workDir/$jobId";
	
	#create a folder for the translation job, named after the job ID
	mkdir($jobPath) or die($forHumans? "Failed to create job directory": $ERROR_CODE);
	
	return $jobId;
}

#####
#
#####
function moveAsyncFile($fileInfo, $jobId) {
	global $workDir, $ERROR_CODE;
	
	$jobPath = "$workDir/$jobId";
	
	move_uploaded_file($fileInfo['tmp_name'], "$jobPath/input.txt")
		or die($forHumans? "Failed to upload file": $ERROR_CODE);
}

#####
#
#####
function checkMosesServerUp($rawhost) {
	$host = str_replace(array("http://", "https://", "/RPC2"), array("", "", ""), $rawhost);

	$fp = fsockopen($host, -1, $errno, $errstr);
	if ($fp) {
		$query = "POST /RPC2 HTTP/1.0\nUser_Agent: My Client\nHost: ".$host."\nContent-Type: text/xml\nContent-Length: 3\n\nXXX\n";

		if (!fputs($fp, $query, strlen($query))) {
			die("Translation/recasing server is down");
		}

		$contents = '';
		while (!feof($fp)) {
			$contents .= fgets($fp);
		}

		fclose($fp);
		
		if (!$contents) {
			die("Translation/recasing server is down");
		}
	}
	else {
		die("Translation/recasing server is down");
	}
}

#####
#
#####
function checkIfServersUp($langPair) {
	global $config;
	
	$langs = explode("-", $langPair);
	$tgtLang = $langs[1];
	
	$trHostHash = confHash($config['translation host list']);
	$rcHostHash = confHash($config['recasing host list']);
	
	checkMosesServerUp($trHostHash[$langPair]);
	checkMosesServerUp($rcHostHash[$tgtLang]);
}

#####
#
#####
function startTranslation($langPair, $jobId, $origFileName, $syncMode) {
  global $workDir, $trScript, $forHumans, $ERROR_CODE, $config;
	
        if (! $config['smartmate_translate']) {
	    checkIfServersUp($langPair);
	}
	
	$cmd = sprintf("perl %s > %s 2>&1",
		"$trScript \"$langPair\" \"$jobId\"" . ($syncMode? "": " \"$origFileName\""),
		"$workDir/$jobId/logfile");
	
	#start the translation script
	if ($syncMode) {
		exec($cmd, $output, $status);
	}
	else {
		exec("$cmd &", $output, $status);
	}
	
	#check if successful
	if ($status != 0) {
		die ($forHumans? "Failed to start translation process; proc status $status": $ERROR_CODE);
	}
}

#####
#
#####
function reportAsyncResults($jobId, $filename) {
	global $forHumans, $ERROR_CODE, $config;
	
	#if the "human" flag is set, report the results in a human-readable way
	if ($forHumans) {
		#call-back was to be done
		if ($config['call-back url']) {
			print "<p>A call-back will be performed once the file is translated</p>";
		}
		else {
			print "<p>$filename is being translated, you can check for results at this <a href=\"checkresults.php?human=1&id=$jobId\">URL</a></p>";
		}
		
		print "<p>or you can go <a href=\"translate.php?human=1\">back</a></p>";
	}
	
	#otherwise, for machine-readable output just print the translation job ID
	else {
		print $jobId;
	}
}

####################################################

#####
#
#####
function displayDemoTranslationForm() {
?>

<html>
<head>
<title>Translation server</title>
<meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
<meta http-equiv="cache-control" content="no-cache"/>
<meta http-equiv="pragma" content="no-cache"/>
<meta http-equiv="expires" content="0"/>
</head>
<body>

<?php
	#just for demo purposes
	#$langPairs = array(
	#	"de-en" => "German-English",
	#	"fr-es" => "French-Spanish",
	#	"de-ja" => "German-Japanese");
	$langPairs = array(
		"en-sv" => "English-Swedish",
		"sv-en" => "Swedish-English");
?>	

<h3>Synchronous translation:</h3>
<form method="post" name="syncForm">
<table border="0">
	<tr>
		<th width="200" align="left">Text to translate: </th>
		<td>
			&nbsp;
		</td>
	</tr>
	<tr>
		<td colspan="2">
			<textarea rows="8" cols="50" name="trText"></textarea>
		</td>
	</tr>
	<tr>
		<th align="left">Language pair:</th>
		<td>
			<select name="langpair">

<?php
	$langPairs = array("en-de-prof" => "English-German PROF",
			   "nl-en" => "Dutch-English",
			   "en-nl" => "English-Dutch",
			   "de-en" => "German-English",
                           "en-de" => "English-German"); 
	foreach ($langPairs as $short => $full) {
		print "\t\t\t<option value=\"$short\">$full</option>\n";
	}
?>

			</select>
		</td>
	</tr>
	<tr>
		<td colspan="2">
			<input type="submit"/>
		</td>
	</tr>
</table>
</form>

<hr/>

<h3>Asynchronous translation (file):</h3>
<form method="post" enctype="multipart/form-data" name="AsyncForm">
<table border="0">
	<tr>
		<th width="200" align="left">File to translate: </th>
		<td>
			<input type="file" name="trFile"/>
		</td>
	</tr>
	<tr>
		<th align="left">Language pair:</th>
		<td>
			<select name="langpair">

<?php
	#just for demo purposes
	$langPairs = array("en-de-prof" => "English-German PROF",
			   "nl-en" => "Dutch-English",
			   "en-nl" => "English-Dutch",
			   "de-en" => "German-English",
                           "en-de" => "English-German"); 
	
	foreach ($langPairs as $short => $full) {
		print "\t\t\t<option value=\"$short\">$full</option>\n";
	}
?>

			</select>
		</td>
	</tr>
	<tr>
		<td colspan="2">
			<input type="submit"/>
		</td>
	</tr>
</table>
</form>

</body>
</html>

<?php
}
?>
