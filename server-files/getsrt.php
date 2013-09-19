<?php

#get common constants and functions from here:
include("trcommon.php");

$jobId = '';

if (isset($_POST['jobId'])) {
	$jobId = $_POST['jobId'];
}

if (isset($_GET['jobId'])) {
	$jobId = $_GET['jobId'];
}

$ERROR_CODE = -1;

$path = "$workDir/$jobId/output.srt";
$translation = file_get_contents($path);

if ($translation === FALSE) {
	print $ERROR_CODE;
}
else {
	print "<pre>0\n$translation</pre>";
}
?>
