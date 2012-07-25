<?php

#get common constants and functions from here:
include("trcommon.php");

#error code to print in case of errors
$ERROR_CODE = "-1";

#backup functionality: if there's no POST request, show a simple HTML form for submitting files;
#works only for the human-readable version
if ($_POST and $_FILES) {
	startNewTranslationSession();
}
else {
	displayFileUploadForm();
}

#####
# function to process the POST request -- starts the translation job
# and registers a new ID in the database; prints the final response
#####
function startNewTranslationSession() {
	global $forHumans, $ERROR_CODE;
	
	#create a DB connection
	$db = initDb($ERROR_CODE);
	
	$langPair = $_POST['langpair'];
	
	$jobIdList = array();
	
	#supports submitting multiple files at once, although this functionality
	#is currently blocked
	foreach ($_FILES as $fileInfo) {
		if ($fileInfo['name']) {
			#start the background translation job
			$jobId = startTranslation($fileInfo, $langPair, $db);
			
			#save the job ID, if successfully registered
			if ($jobId) {
				$jobIdList[$jobId] = $fileInfo['name'];
			}
			else if ($forHumans) {
				print "<p>Error processing " . $fileInfo['name'] . "</p>";
			}
			else {
				print $ERROR_CODE;
			}
		}
	}
	
	#print the job ID or a human-readable response
	reportResults($jobIdList);
}

#####
#
#####
function getNewId($db, $filename) {
	global $forHumans, $ERROR_CODE;
	
	#create a statement for registering a new job ID in the database;
	#entry initiated with a FALSE (0) value for the "is_done" field
	$stmt = $db->prepare("insert into trids(is_done, filename) values(0, ?)") or die($forHumans? "Failed to prepare statement": $ERROR_CODE);
	$stmt->execute(array($filename)) or die($forHumans? "Failed to get ID": $ERROR_CODE);
	
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
function startTranslation($fileInfo, $langPair, $db) {
	global $workDir, $trScript, $forHumans, $ERROR_CODE;
	
	$origFileName = $fileInfo['name'];
	
	#get the new job ID via DB
	$jobId = getNewId($db, $origFileName);
	$jobPath = "$workDir/$jobId";
	
	#create a folder for the translation job, named after the job ID
	mkdir($jobPath) or die($forHumans? "Failed to create job directory": $ERROR_CODE);
	
	#place the uploaded subtitle file in the job directory
	move_uploaded_file($fileInfo['tmp_name'], "$jobPath/input.txt") or die($forHumans? "Failed to upload file": $ERROR_CODE);
	
	#start the background translation script
	$status = exec(sprintf("%s > %s 2>&1 &",
		"$trScript \"$langPair\" \"$jobId\" \"$origFileName\"",
		"$workDir/$jobId/logfile"));
	
	#check if successful
	if ($status != 0) {
		die ($forHumans? "Failed to start translation process; proc status $status": $ERROR_CODE);
	}
	
	return $jobId;
}

#####
#
#####
function reportResults($jobIdList) {
	global $forHumans, $ERROR_CODE, $config;
	
	#multiple file processing is currently switched off
	if (count(array_keys($jobIdList)) != 1) {
		print $ERROR_CODE; #unless there's one ID to report, print an error code
	}
	
	#if the "human" flag is set, report the results in a human-readable way
	else if ($forHumans) {
		
		#call-back was to be done
		if ($config['call-back url']) {
			print "<p>A call-back will be performed once the file is translated</p>";
		}
		else {
			foreach ($jobIdList as $jobId => $filename) {
				print "<p>$filename is being translated, you can check for results at this <a href=\"checkresults.php?human=1&id=$jobId\">URL</a></p>";
			}
		}
		
		print "<p>or you can go <a href=\"translate.php?human=1\">back</a></p>";
	}
	
	#otherwise, for machine-readable output just print the translation job ID
	else {
		$keys = array_keys($jobIdList);
		print $keys[0];
	}
}

####################################################

#####
#
#####
function displayFileUploadForm() {
?>

<html>
<head>
<title>Translation server prototype</title>
</head>
<body>

<form method="post" enctype="multipart/form-data">
<table border="0">
	<tr>
		<th align="left">File to translate: </th>
		<td>
			<input type="file" name="trFile"/>
		</td>
	</tr>
	<tr>
		<th align="left">Lang. pair:</th>
		<td>
			<select name="langpair">

<?php
	#just for demo purposes
	$langPairs = array("de-en" => "German-English"); 
	
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
