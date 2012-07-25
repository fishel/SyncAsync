<?php

#get common constants and functions from here:
include("trcommon.php");

$ERROR_CODE = "";

#the job ID to check
$id = $_GET['id'];

if (!$id) {
	die($forHumans? "Please give me an ID to play with": $ERROR_CODE);
}

#initialize DB connection
$db = initDb($ERROR_CODE);

#check the job status
$jobInfo = checkJob($db, $id, $ERROR_CODE);

$outcome = $jobInfo['is_done'];

#if the job is done, it can be displayed and then cleaned up
if ($outcome == 1) {
	$jobPath = "$workDir/$id";
	
	#get the subtitle lines -- TODO NB! have to test with UTF8
	exec("cat $jobPath/detok.txt", $subtitleLines);
	
	#display the subtitle file
	print implode(($forHumans? "<br>": "\n"), $subtitleLines);
	
	#remove the job directory
	#exec("rm -r $jobPath");
	
	#clean up the job DB entry
	clearJobEntry($db, $id, $ERROR_CODE);
}
else {
	print "someone has been here before me";
}

?>
