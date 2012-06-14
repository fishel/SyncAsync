<?

#get common constants and functions from here:
include("trcommon.php");

$ERROR_CODE = "2";

#the job ID to check
$id = $_GET['id'];

if (!$id) {
	die($forHumans? "Please give me an ID to play with": $ERROR_CODE);
}

#initialize DB connection
$db = initDb($ERROR_CODE);

#find out the job status
$jobInfo = checkJob($db, $id, $ERROR_CODE);

$outcome = $jobInfo['is_done'];
$filename = $jobInfo['filename'];

#for humans print a "pending" message with progress, or
#a "done" message
if ($forHumans) {
	if ($outcome == 1) {
		print "<p>Translation of `$filename' has finished, you can <a href=\"getresults.php?id=$id&human=1\">download</a> the result</p>";
	}
	#if it is still being translated, print a code for the machine-readable
	#version, or the progress for the human-readable version
	else if ($outcome == 0) {
		$jobPath = "$workDir/$id";
		
		exec("cat $jobPath/input.txt | wc -l", $totalRaw);
		exec("cat $jobPath/output.txt | wc -l", $readyRaw);
		
		$total = 0 + $totalRaw[0];
		$ready = 0 + $readyRaw[0];
		
		print "<p>Translation of `$filename' is running, $ready / $total rows translated</p>";
	}
	else {
		print "<p>There was an error while translating `$filename', please start over</p>";
	}

	print "<p>Also you can go and have some more files <a href=\"translate.php?human=1\">translated</a></p>";
}
#for machine-readable output, print the DONE code (1) or PENDING code (0)
else {
	print $outcome? $outcome: "0";
}

?>
