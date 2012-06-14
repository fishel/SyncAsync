<?
	#path to the SQLite DB file
	$dbPath = "/home/mfishel/offweb/db/trids.sqlite";

	#base path where translation job directories will be created
	$workDir = "/home/mfishel/offweb/translations";

	#translation script path
	$trScript = "/home/mfishel/www/sumat/trsrvdemo/translate_file.pl";

	#support 2 kinds of output -- human-readable and machine-readable
	$forHumans = isset($_GET['human']);
	
	#####
	# prepare a connection to the SQLite database for job ID management
	#####
	function initDb($errorCode) {
		global $dbPath, $forHumans;
		
		#open a connection
		$result = new PDO("sqlite:$dbPath", "", "", array(PDO::ATTR_PERSISTENT => false));
		
		#check if successful
		if (!$result) {
			die($forHumans? "failed to connect to local DB": $errorCode);
		}
		
		return $result;
	}
	
	#####
	# check the status of a job
	#####
	function checkJob($db, $id, $ERROR_CODE) {
		#find out the job status
		$stmt = $db->prepare("select is_done, filename from trids where id = ?")
			or die($forHumans? "Failed to prepare statement": $ERROR_CODE);
		$stmt->execute(array($id))
			or die($forHumans? "Failed to execute statement": $ERROR_CODE);

		$result = $stmt->fetch();

		#if the job ID has not been registered, report an error
		if (!$result) {
			die($forHumans? "None such job ID registered": $ERROR_CODE);
		}
		
		return $result;
	}
	
	#####
	# clear the job entry
	#####
	function clearJobEntry($db, $id, $ERROR_CODE) {
		#find out the job status
		$stmt = $db->prepare("delete from trids where id = ?")
			or die($forHumans? "Failed to prepare statement": $ERROR_CODE);
		
		$stmt->execute(array($id))
			or die($forHumans? "Failed to execute statement": $ERROR_CODE);
	}
?>
