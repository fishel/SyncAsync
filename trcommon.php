<?
	$config = loadConfig();
	
	#path to the SQLite DB file
	$dbPath = $config["db path"];

	#base path where translation job directories will be created
	$workDir = $config["work dir"];

	#translation script path
	$trScript = $config["translation script"];

	#support 2 kinds of output -- human-readable and machine-readable
	$forHumans = isset($_GET['human']);
	
	if (!$forHumans) {
		die("-1\nService in reconstruction");
	}
	
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
	
	#####
	#
	#####
	function loadConfig() {
		$result = array();
		
		$configFilePath = "config.ini";
		
		$fh = @fopen($configFilePath, "r");
		
		if ($fh) {
			while (($buffer = fgets($fh)) !== false) {
				$normBuf = normalize($buffer);
				
				if (strlen($normBuf) == 0 or substr($normBuf, 0, 1) == "#") {
					#empty or comment line, do nothing
				}
				else if (preg_match('/^([^=]+)=(.*)$/', $normBuf, $matches)) {
					$key = trim($matches[1]);
					$value = trim($matches[2]);
					
					if (!$value) {
						$value = readMultilineValue($fh);
					}
					
					$result[$key] = $value;
				}
				else {
					die("Failed to parse config line `$normBuf'");
				}
			}
			if (!feof($fh)) {
				die("Failed to read the config file");
			}
			
			fclose($fh);
		}
		else {
			die("Failed to open the config file");
		}
		
		return $result;
	}
	
	#####
	#
	#####
	function readMultilineValue($fh) {
		$val = "";
		
		$buf = fgets($fh);
		$tbuf = trim($buf);
		
		while ($buf !== false and strlen($tbuf) > 0 and substr($tbuf, 0, 1) != "#") {
			$val .= $tbuf . "\n";
			
			$buf = fgets($fh);
			$tbuf = trim($buf);
		}
		
		return $val;
	}
	
	#####
	#
	#####
	function normalize($str) {
		return preg_replace('/\s+/', ' ', trim($str));
	}
?>
