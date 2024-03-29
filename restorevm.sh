#!/bin/bash
# Proxmox restore script by Thelogh
#Bash script for automatic restore of VMs from the Proxmox Backup Server (PBS) 3.X to the Proxmox VE 8.1.X
#The script allows the restoration of the "VM" from a backup, the synchronization of the disks, and the use of snapshots on ZFS to maintain previous versions.
#https://www.alldiscoveries.com/prevent-long-disaster-recovery-on-hyper-converged-ceph-cluster-with-proxmox-v8-with-high-availability/
#For all requests write on the blog
#REPOSITORY
#https://github.com/thelogh/proxmox-restore-script
#V.1.0.0
#
#----------------------------------------------------------------------------------#
############################# START CONFIGURATION OPTIONS ##########################
#----------------------------------------------------------------------------------#
#INSERT ACTUAL PATH ON CRONTAB
#echo $PATH
#INSERT THE RESULT ON CORONTAB
#PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#export -p
#LIST LATEST BACKUP
#proxmox-backup-client snapshot list --repository backupread@pbs@192.168.200.2:DATASTORE

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#SERVER NAME
SERVERNAME="PVE-B"

#DESTINATION EMAIL
TO="your@email.com"

#LIST OF VMs IN ARRAY TO PROCESS=("100" "101" "102")
VM=("100")

#DEFINE PBS
#PBS_BACKUP_DIR
#PBS_BACKUP_NAME
#PBS_NAMESPACE

#USERNAME FOR AUTENTICATION PBS
pbsuser="backupread@pbs"

#PBS_PASSWORD
export PBS_PASSWORD="Strongpassword!"

#DATASTORE PBS
pbsdatastore="DATASTORE"

#IP PBS
pbsip="192.168.200.2"

#SURCE PBS
pbssource="proxmox-backup"

#CONTROL VARIABLE FOR SYNC DISK OR RESTORE, 1 ENABLED, 0 DISABLED
SYNCDISK=1

#CONTROL VARIABLE FOR SYNC DISK METOD = BLOCKSYNC 0, BDSYNC 1
SYNCDISKTYPE=1

##VARIABLE NUMBER SNAPSHOT ZFS TO KEEP COMBINED WITH WITH SYNCDISK, 0 DISABLE 
SYNCDISKSNAP=21

#SCRIPT SYNC BLOCK LOCATION
BLOCKSYNC="/root/blocksync.py"

#BLOCK SIZE FOR TRANSFER
#DEFAULT 1MB = 1024 * 1024 = 1048576
#BLOCKSYNCSIZE="4194304"
#BLOCKSYNCSIZE="1048576"
BLOCKSYNCSIZE="1048576"
#TYPE OF HASH TO USE
#DEFAULT sha512
#
BLOCKSYNCHASH1="blake2b"

#TYPE OF HASH TO USE
#DEFAULT md5
#LIST openssl list -digest-algorithms
#blake2b512 SHA3-512 SHA512
BDSYNCHASH1="blake2b512"
#BDSYNCHASH1="SHA512"

#TEMPORARY DIRECTORY FOR SAVING DIFF FILES
BDSYNCTEMPDIR="/root/bdsynctmp"

#DEFAULT BLOCK 4096
BDSYNCSIZEBLOCK="1048576"
#BDSYNCSIZEBLOCK="1048576"

#LOCAL DESTINATION POOL
# FIND IN /etc/pve/storage.cfg
pooldestination="pool-data"
#TYPE
typesource="backup"

#BLOCK THE REPLICATION PROCESS IN CASE OF ERROR "1" TO EXIT, "0" TO CONTINUE IN CASE OF ERROR
ERROREXIT="1"

#INSERT THE REPLICA PROGRESS IN THE LOG, 1 ENABLED, 0 DISABLED
REPLICALOG="1"

#LOG SIMPLE, 1 ENABLED, 0 DISABLED
LOGSIMPLE="0"

#TEMPORARY DESTINATION DIRECTORY LOG
DIRTEMP="/tmp"
#LOG DIRECTORY
LOGDIR="${DIRTEMP}/vmrestore"
#LOG
LOG="${LOGDIR}/restorevm.log"
#ERROLOG
ELOG="${LOGDIR}/restorevm-error.log"
#CONTROL VARIABLE
ERRORCODE="0"
#VM REPLY EMAIL MESSAGE SUBJECT
MSG="${SERVERNAME} VM replication report"
MSGERROR="${SERVERNAME} ERROR VM Replication Report"

#PBS_REPOSITORY
export PBS_REPOSITORY="${pbsuser}@${pbsip}:${pbsdatastore}"

#----------------------------------------------------------------------------------#
############################# END CONFIGURATION OPTIONS ##########################
#----------------------------------------------------------------------------------#

function send_mail {
	#I CHECK THE EXISTENCE OF THE SHIPPING LOGS
	if [[ -f ${LOG} && -f ${ELOG} ]]; 
		then
		if [ ${ERRORCODE} -eq 0 ];
			then
			#NO ERROR
			cat ${LOG} ${ELOG} | mail -s ${MSG} ${TO}
		else
			#ERROR IN REPLICATION, I ATTACH THE LOGS
			cat ${LOG} ${ELOG} | mail -s ${MSGERROR} ${TO}
		fi
	else
		#THERE ARE NO LOGS
		if [ ${ERRORCODE} -eq 0 ];
			then
			#NO ERRORS BUT THERE ARE NO LOGS
			echo ${MSGERROR} | mail -s ${MSGERROR} ${TO}
		else
			#REPLICATION ERRORS AND THERE ARE NO LOGS
			echo ${MSGERROR} | mail -s ${MSGERROR} ${TO}
		fi
	fi
}

#CHECK THE EXIT STATUS OF THE PROGRAM OR COMMAND LAUNCHED
function controlstate {
	if [ $? -ne 0 ];
		then
		echo "Error executing the command" 
		#I INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
	fi
	#CHECK IF IT IS NECESSARY TO FINISH THE RESET PROCEDURE IN THE PRESENCE OF ERRORS
	if [ ${ERROREXIT} != 0 ];
		then
		#echo "In case of errors I end the backup"
		if [ ${ERRORCODE} != 0 ];
			then
			echo "There are errors, I'm stopping replication"
			send_mail
			exit 1
		fi
	fi
}

#I INCREASE THE ERROR CONTROL VARIABLE
function controlerror {

((ERRORCODE++))

}

#CHECK IF THE DESTINATION DIRECTORY EXISTS
function controldir {
if [ ! -d $1 ];
	then
		echo "Directory $1 does not exist, I create it"
		/bin/mkdir -p $1
		controlstate
fi
}

#VERIFY THAT THE JQ PROGRAM IS INSTALLED
function controljq {
	#apt-get install jq
	if ! jq -V &> /dev/null
		then
		echo "jq could not be found"
		echo "Install with apt-get install jq "
		#I INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi
}

#VM LOCK FUNCTION
function setqemuvmlock {
	vid=$1
	qm set $vid --lock backup
	if [ $? -ne 0 ];
		then
		echo "Error set lock mode backup for VM $vid" 
		#INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi
}

#VM LOCK REMOVE FUNCTION
function remqemuvmlock {
	vid=$1
	qm unlock $vid
	if [ $? -ne 0 ];
		then
		echo "Error remove lock for VM $vid" 
		#INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi
}

#VM CREATION FUNCTION
function restorevm (){
	#$bktype $vmid $lastbackuptime
	bkt=$1
	vid=$2
	backuptime=$3
	if [ ${LOGSIMPLE} -eq 0 ];
		then
		echo "Starting Recovery"
	fi
	if [ ${REPLICALOG} -eq 1 ];
		then
		#Log Replication Enabled
		qmrestore $pbssource:$typesource/$bkt/$vid/$backuptime $vid --storage $pooldestination
		controlstate
	else
		qmrestore $pbssource:$typesource/$bkt/$vid/$backuptime $vid --storage $pooldestination > /dev/null
		controlstate
	fi

	if [ ${LOGSIMPLE} -eq 0 ];
		then
		#I SET THE DATE IN THE DESCRIPTION TO IDENTIFY THE BACKUP VERSION
		qm set $vid --description $backuptime
		controlstate
		#DISABLE START VM ON BOOT
		qm set $vid --onboot 0
		controlstate
		echo "Restore completed"
	else
		#I SET THE DATE IN THE DESCRIPTION TO IDENTIFY THE BACKUP VERSION
		qm set $vid --description $backuptime > /dev/null
		controlstate
		#DISABLE START VM ON BOOT
		qm set $vid --onboot 0 > /dev/null
		controlstate
	fi
	
}

#VM CREATION SNAPSHOT FUNCTION
function takesnap (){
	#takesnap $vmid $curdesc $lastbackuptime
	vid=$1
	desctime=$2
	newdesctime=$3
	
	#COUNTER SNAPSHOT FOUND
	snapcount=0
	
	#SNAPSHOT LIST
	snapshotstate=$(qm listsnapshot $vid)

	#SAVE THE RESULT IN AN ARRAY WITH DELIMITER \r
	readarray -t snapshotstatelist <<<"$snapshotstate"
	
	#EMPTY VARIABLE FOR OLDER SNAPSHOT DATE
	oldersnap=""
	#EMPTY VARIABLE FOR OLDER SNAPSHOT
	oldersnaptime=""
	
	#EMPTY VARIABLE FOR NEWEST SNAPSHOT DATE
	newestsnap=""
	
	#CHECK FOR MORE SNAPSHOT
	for snapc in ${!snapshotstatelist[@]}; do

		#CLEAR THE SNAPSHOT NAME FROM THE SPACES
		listsnap=$(echo ${snapshotstatelist[$snapc]} | sed 's/^[ \t]*//g' )
		
		#IF IT IS NOT THE CURRENT STATUS
		if [[ ! "${listsnap}" =~ ^"\`-> current" ]];
			then
			#SAVE THE OLDEST SNAPSHOT TO DELETE
			#EXTRACT THE NAME OF THE SNAPSHOT
			snapnametime=$(echo ${listsnap} | awk -F " " '{print $2}' )
			#EXTRACT THE DATE FROM THE NAME
			snapname=$(echo ${snapnametime} | sed 's/^s//g;s/_/:/g' )
			
			if [[ ${snapc} -eq 0 ]];
				then
				#SAVE THE OLDEST SNAPSHOT
				oldersnap=$snapname
				oldersnaptime=$snapnametime
			fi
			#SAVE THE NEWEST SNAPSHOT
			newestsnap=$snapname
			((snapcount++))
		fi
	done
	
	#CHECK THE NUMBER OF SNAPSHOTS PRESENT
	if [[ ${snapcount} -gt ${SYNCDISKSNAP} ]];
		then
		#ERROR, THE NUMBER OF SNAPSHOTS PRESENT EXCEEDS THOSE ALLOWED
		echo "Error, The number of snapshots present exceeds those allowed for the VM $vid" 
		#I INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi
	
	#CREATE THE FORMAT FOR THE SNAPSHOT NAME
	backuptimemod=$(echo ${desctime} | sed 's/:/_/g' )
	newsnapshot="s$backuptimemod"
	
	#CHECK THAT THERE IS AT LEAST ONE SNAPSHOT OTHERWISE I WILL CREATE IT
	if [[ -z "$oldersnap" ]] && [[ -z "$oldersnaptime" ]];
		#THERE ARE NO PREVIOUS SNAPSHOT I CREATE THE SNAPSHOT
		then
		#CREATE THE NEW SNAPSHOT
		echo "There are no previous snapshot i create the snapshot $newsnapshot for the VM $vid"
		qm snapshot $vid $newsnapshot > /dev/null
		if [ $? -ne 0 ];
			then
			echo "Error creating snapshot for VM $vid" 
			#INCREASE THE CONTROL COUNTER AND PROCEED
			controlerror
			#SEND EMAIL REPORT
			echo "Sending report email"
			send_mail
			exit 1
		fi
	else
		#THERE ARE PREVIOUS SNAPSHOT, DELETE AND CREATE THE SNAPSHOT
		#MAKE SURE THAT THE NAME OF THE SNAPSHOT DOES NOT COINCIDE WITH THE NAME OF THE BACKUP DATE IN THE NOTES
		if [[ "${newestsnap}" == "${desctime}" ]];
			then
			echo "Error, the snapshot name matches the current backup date for the VM $vid" 
			#INCREASE THE CONTROL COUNTER AND PROCEED
			controlerror
			#SEND EMAIL REPORT
			echo "Sending report email"
			send_mail
			exit 1
		fi
		
		#I CHECK THAT THE NUMBER OF SNAPSHOTS IS LESS OR EQUAL TO THE MAXIMUM NUMBER
		if [[ ${snapcount} -le ${SYNCDISKSNAP} ]];
			then
			#IF IT IS THE SAME I DELETE THE OLDEST SNAPSHOT
			if [[ ${snapcount} -eq ${SYNCDISKSNAP} ]];
				then
					#DELETE THE SNAPSHOT
					echo "Deleting old snapshot $oldersnaptime for VM $vid"
					qm delsnapshot $vid $oldersnaptime
					if [ $? -ne 0 ];
					then
						echo "Error deleting snapshot for VM $vid" 
						#INCREASE THE CONTROL COUNTER AND PROCEED
						controlerror
						#SEND EMAIL REPORT
						echo "Sending report email"
						send_mail
						exit 1
					fi
			fi
			#CREATE THE NEW SNAPSHOT
			echo "Creating snapshot $newsnapshot for VM $vid"
			qm snapshot $vid $newsnapshot > /dev/null
			if [ $? -ne 0 ];
				then
				echo "Error creating snapshot for VM $vid" 
				#INCREASE THE CONTROL COUNTER AND PROCEED
				controlerror
				#SEND EMAIL REPORT
				echo "Sending report email"
				send_mail
				exit 1
			fi
		fi
	fi
}

#VM BDSYNC SYNC DISK FUNCTION
function bdsyncstart (){
	#$mapstatedev $curvmdiskconfpool $curvmdiskconfname
	srcdev=$1
	zfspool=$2
	diskdst=$3
	controldir ${BDSYNCTEMPDIR}

	#START TIME COUNTER FOR DIFF FILE CREATION
	starbdsync=`date +%s`
	
	echo "Bdsync Start `date +%Y/%m/%d-%H:%M:%S` creation of diff file for disk $diskdst"
	
	#CHECK WHETHER TO SAVE LOG OUTPUT
	if [[ ${REPLICALOG} -eq 1 ]] && [[ ${LOGSIMPLE} -eq 0 ]];
		then
		bdsync --zeroblocks "bdsync --server" $srcdev /dev/zvol/$zfspool/$diskdst --progress --zeroblocks --hash=$BDSYNCHASH1 --blocksize=$BDSYNCSIZEBLOCK | zstd -z -T0 > $BDSYNCTEMPDIR/$diskdst.zst
	else
		bdsync --zeroblocks "bdsync --server" $srcdev /dev/zvol/$zfspool/$diskdst --zeroblocks --hash=$BDSYNCHASH1 --blocksize=$BDSYNCSIZEBLOCK | zstd -z -T0 > $BDSYNCTEMPDIR/$diskdst.zst
	fi
	if [ $? -ne 0 ];
		then
		echo "Serious error in Bdsync disk synchronization interrupted for Disk $diskds `date +%Y/%m/%d-%H:%M:%S`" 
		#INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi
	#STOP TIME COUNTER FOR DIFF FILE CREATION
	stopbdsync=`date +%s`

	synctime=$( echo "$stopbdsync - $starbdsync" | bc -l )
	synctimehours=$((synctime / 3600));
	synctimeminutes=$(( (synctime % 3600) / 60 ));
	synctimeseconds=$(( (synctime % 3600) % 60 ));
	
	echo "Bdsync End `date +%Y/%m/%d-%H:%M:%S` creation of diff file for disk $diskdst"
	
	echo "Bdsync creation of diff file for $diskdst disk completed in: $synctimehours hours, $synctimeminutes minutes, $synctimeseconds seconds"
	
	#START TIME COUNTER FOR DIFF FILE APPLICATION
	starbdsyncrestore=`date +%s`
	
	echo "Bdsync Start `date +%Y/%m/%d-%H:%M:%S` apply diff file for disk $diskdst"
	
	#APPLY THE DIFF FILE TO THE DISK
	zstd -d -T0 < $BDSYNCTEMPDIR/$diskdst.zst | bdsync --patch=/dev/zvol/$zfspool/$diskdst
	if [ $? -ne 0 ];
		then
		echo "Serious error in Bdsync apply diff disk synchronization interrupted for Disk $diskds `date +%Y/%m/%d-%H:%M:%S`" 
		#INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi
	#STOP TIME COUNTER FOR DIFF FILE CREATION
	stopbdsyncrestore=`date +%s`
	
	syncrestoretime=$( echo "$stopbdsyncrestore - $starbdsyncrestore" | bc -l )
	syncrestoretimehours=$((syncrestoretime / 3600));
	syncrestoretimeminutes=$(( (syncrestoretime % 3600) / 60 ));
	syncrestoretimeseconds=$(( (syncrestoretime % 3600) % 60 ));
	echo "Bdsync End `date +%Y/%m/%d-%H:%M:%S` apply diff file for disk $diskdst"

	echo "Bdsync application of diff file for $diskdst disk completed in: $syncrestoretimehours hours, $syncrestoretimeminutes minutes, $syncrestoretimeseconds seconds"
	#REMOVE DIFF FILE
	echo "Remove diff file $BDSYNCTEMPDIR/$diskdst.zst"
	rm $BDSYNCTEMPDIR/$diskdst.zst
	controlstate

}

#VM SYNC DISK FUNCTION
function syncdiskvm (){

	#$bktype $vmid $lastbackuptime
	bkt=$1
	vid=$2
	backuptime=$3

	#DISC FOUND CHECK COUNTER
	finddisk="0"

	#RESTORED DISK VERIFICATION COUNTER
	restoredisk="0"
	
	#I PUT THE VM IN LOCK MODE TO SYNCHRONIZE THE DISKS
	setqemuvmlock $vid

	#SAVE THE LIST OF DISKS IN AN ARRAY
	arraydisk=$(proxmox-backup-client list --output-format=json-pretty | jq -r '.[] |select(."backup-id" == "'$vid'" and ."backup-type" == "'$bkt'")."files"'| sed 's/[][]//g;s/\,//g;s/\s//g;s/\"//g')
	
	#CHECK IF THE ARRAYDISK VALUE EXISTS
	if [ -z "$arraydisk" ];
		then
		echo "Attention! Problem recovering the files list for VM $vid"
		#I INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi
	
	#SAVE THE DISK MAP FROM THE BACKUP CONFIGURATION FILE
	unmaparraydiskmap=$(proxmox-backup-client restore $bkt"/"$vid"/"$backuptime qemu-server.conf - | grep "^#qmdump#map" )
	
	#SAVE THE RESULT IN AN ARRAY WITH DELIMITER \r
	readarray -t arraydiskmap <<<"$unmaparraydiskmap"
	
	#CHECK IF THE ARRAYDISKMAP VALUE EXISTS
	if [ -z "$arraydiskmap" ];
		then
		echo "Attention! Problem recovering the map files list for VM $vid"
		#I INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi
	
	#CHECK HOW MANY DISK ARE AVAILABLE
	for diskimg in $arraydisk; do
		if [[ "$diskimg" == *.img.fidx ]];
			then
			#DISC FOUND CHECK COUNTER
			((finddisk++))
			#MAP THE CONTENT INTO STRING FORMAT
			unmapstring=$(proxmox-backup-client unmap 2>&1)
			
			#CHECK THAT THE COMMAND REPORTS THE MAP
			if [[ "$unmapstring" != "Nothing mapped." ]];
			then
				#SAVE THE RESULT IN AN ARRAY WITH DELIMITER \r
				readarray -t unmaparray <<<"$unmapstring"

				#START LOOP LIST OF MOUNTED DISK
				for unmapdev in ${!unmaparray[@]}; do

					#SAVE THE MOUNTED "DEVICE".
					devdisk=$(echo ${unmaparray[$unmapdev]} | awk -F " " "/$pbsdatastore/{print \$1}" |sed 's/://g')
					#SAVE THE MOUNT PATH
					diskmountpoint=$(echo ${unmaparray[$unmapdev]} | awk -F " " "/$pbsdatastore/{print \$2}")

					#CHECK VM ID
					mountid=$(echo $diskmountpoint | grep -oE ":$bkt/.{,3}" | cut -c5-7)
					
					#CHECK THAT THE DISK ALREADY "MAP" IS NOT THE ONE OF THE VM TO SYNCHRONIZE
					if [ "$mountid" == "$vid" ];
					then
						echo "Attention! Problem there are already disks mounted for this VM $vid"
						#INCREASE THE CONTROL COUNTER AND PROCEED
						controlerror
						#SEND EMAIL REPORT
						echo "Sending report email"
						send_mail
						exit 1
					fi
				done
			fi
			#THERE ARE NO DISKS MOUNTED I WILL CONTINUE

			#CLEAR THE NAME OF THE DISK
			diskimgmnt=$(echo $diskimg | sed 's/.fidx//g')

			#MOUNT THE VIRTUAL DISC
			mapstate=$(proxmox-backup-client map $bkt"/"$vid"/"$backuptime $diskimgmnt 2>&1)
			#CHECK THE STATUS OF THE COMMAND MAP
			if [[ $mapstate =~ "Error:" ]];
				then
				echo "Attention! Problem map disk for VM $vid"
				#I INCREASE THE CONTROL COUNTER AND PROCEED
				controlerror
				#SEND EMAIL REPORT
				echo "Sending report email"
				send_mail
				exit 1
			else
				#NOT IN ERROR CONTINUE

				#SAVE THE MAP DEVICE /dev/loopXX
				mapstatedev=$(echo $mapstate| grep -oE '/dev/.{,7}')

				#CHECK IF THE LOCK VALUE EXISTS
				if [[ -z "$mapstatedev" ]];
					then
					echo "Attention! Problem retrieving the current map device on the VM $vid "
					#I INCREASE THE CONTROL COUNTER AND PROCEED
					controlerror
					#SEND EMAIL REPORT
					echo "Sending report email"
					send_mail
					exit 1
				fi

				#FIRST CHECK THE DISK MAP FROM THE BACKUP CONFIGURATION FILE qemu-server.conf
				
				#START THE LOOP TO SEARCH FOR DISK DEVICE
				for dkmap in ${!arraydiskmap[@]}; do

					#SAVE THE MAP "DEVICE".
					##qmdump#map:virtio1:drive-virtio1:rbd:raw:
					mapdkstr=$(echo ${arraydiskmap[$dkmap]} |  sed 's/#qmdump#map://g')
					
					#SAVE DEVICE TYPE virtio0 scsi0
					mapdevice=$(echo $mapdkstr | awk -F ":" '{print $1}')
					#SAVE DISK NAME drive-virtio0 drive-scsi0
					mapdsk=$(echo $mapdkstr | awk -F ":" '{print $2}')
					
					#CHECK THAT "MAP" IS CORRECT
					if [[ -z "$mapdevice" ]] || [[ -z "$mapdsk" ]] ;
					then
						echo "Attention! Problem identifying the map on the VM $vid"
						#INCREASE THE CONTROL COUNTER AND PROCEED
						controlerror
						#SEND EMAIL REPORT
						echo "Sending report email"
						send_mail
						exit 1
					fi
					#IDENTIFY THE NAME OF THE CURRENT DISK MOUNTED TO FIND IT IN THE MAP DEVICE drive-virtio0 drive-scsi0
					diskimgmntsp=$(echo $diskimgmnt | sed 's/.img//g')
					
					#CHECK THAT THE MOUNTED DISK HAS MAPPING
					if [ $diskimgmntsp == $mapdsk ];
					then
						#SAVE THE CURRENT CONFIGURATION IN QEMU AND
						#CLEAR THE CONFIGURATION STRING TO EXTRACT THE DATA scsi0,pool-data,vm-701-disk-0,iothread=1,size=8G
						curvmdiskconf=$(qm config $vid | grep "^$mapdevice: "| sed 's/ //g;s/:/,/g')
						
						#SAVE THE CONFIGURED UTILIZED POOL
						curvmdiskconfpool=$(echo $curvmdiskconf | awk -F "," '{print $2}')
						
						#CHECK IF THE LOCK VALUE EXISTS
						if [[ -z "$curvmdiskconfpool" ]];
							then
							echo "Attention! Problem retrieving the current poll on the VM $vid "
							#I INCREASE THE CONTROL COUNTER AND PROCEED
							controlerror
							#SEND EMAIL REPORT
							echo "Sending report email"
							send_mail
							exit 1
						fi
					
						#SAVE THE NAME OF THE DISC
						curvmdiskconfname=$(echo $curvmdiskconf | awk -F "," '{print $3}')
						
						#CHECK IF THE LOCK VALUE EXISTS
						if [[ -z "$curvmdiskconfname" ]];
							then
							echo "Attention! Problem retrieving the current disk name on the VM $vid "
							#I INCREASE THE CONTROL COUNTER AND PROCEED
							controlerror
							#SEND EMAIL REPORT
							echo "Sending report email"
							send_mail
							exit 1
						fi

						#VERIFY THAT THE DESTINATION POLL OF THE SCRIPT AND THE ONE CONFIGURED IN THE VM ARE THE SAME
						if [[ "$pooldestination" == "$curvmdiskconfpool" ]];
							then			

							#CHECK WHETHER TO SAVE LOG OUTPUT
							if [ ${REPLICALOG} -eq 1 ];
								then 
								#PROCEED WITH STARTING SYNC DISK
								if [ ${SYNCDISKTYPE} -eq 0 ];
									then
									echo "Starting disk synchronization with Blocksync `date +%Y/%m/%d-%H:%M:%S`"
									python3 $BLOCKSYNC $mapstatedev localhost /dev/zvol/$curvmdiskconfpool/$curvmdiskconfname -b $BLOCKSYNCSIZE -1 $BLOCKSYNCHASH1 -f
									if [ $? -ne 0 ];
										then
										echo "Serious error in disk synchronization interrupted" 
										#I INCREASE THE CONTROL COUNTER AND PROCEED
										controlerror
										#SEND EMAIL REPORT
										echo "Sending report email"
										send_mail
										exit 1
									fi
									echo "End disk synchronization with Blocksync `date +%Y/%m/%d-%H:%M:%S`"
								else
									#echo "Starting disk synchronization with Bdsync `date +%Y/%m/%d-%H:%M:%S`"
									bdsyncstart $mapstatedev $curvmdiskconfpool $curvmdiskconfname
								fi
							else
								#PROCEED WITH STARTING SYNC DISK
								if [ ${SYNCDISKTYPE} -eq 0 ];
									then
									echo "Starting disk synchronization with Blocksync `date +%Y/%m/%d-%H:%M:%S`"
									python3 $BLOCKSYNC $mapstatedev localhost /dev/zvol/$curvmdiskconfpool/$curvmdiskconfname -b $BLOCKSYNCSIZE -1 $BLOCKSYNCHASH1 -f > /dev/null
									if [ $? -ne 0 ];
										then
										echo "Serious error in disk synchronization interrupted" 
										#I INCREASE THE CONTROL COUNTER AND PROCEED
										controlerror
										#SEND EMAIL REPORT
										echo "Sending report email"
										send_mail
										exit 1
									fi
									echo "End disk synchronization with Blocksync `date +%Y/%m/%d-%H:%M:%S`"
								else
									#echo "Starting disk synchronization with Bdsync"
									bdsyncstart $mapstatedev $curvmdiskconfpool $curvmdiskconfname > /dev/null
								fi
							fi
							#IF THERE HAVE BEEN NO ERRORS UNMAP THE DISK
		
							#I MAP THE CONTENT INTO STRING FORMAT
							unmapstatus=$(proxmox-backup-client unmap $mapstatedev 2>&1)
							
							#INCREASE THE SYNCHRONIZED DISK COUNTER
							((restoredisk++))
							
						else
							echo "Attention! The target poll ($pooldestination)is different from the configured ($curvmdiskconfpool) one for VM $vid"
							#INCREASE THE CONTROL COUNTER AND PROCEED
							controlerror
							#SEND EMAIL REPORT
							echo "Sending report email"
							send_mail
							exit 1
						fi # FINISH VERIFY THAT THE DESTINATION POLL OF THE SCRIPT AND THE ONE CONFIGURED IN THE VM ARE THE SAME	
					fi
				done #FINISH START THE LOOP TO SEARCH FOR DISK DEVICE
			fi # FINISH CHECK THE STATUS OF THE COMMAND MAP
		fi #END OF DISK .IMG.FIDX PRESENCE
	done #FINE CHECK HOW MANY DISK ARE AVAILABLE

	#CHECK IF AT LEAST ONE DISK HAS BEEN FOUND OTHERWISE I GET AN ERROR
	if [ $finddisk -eq 0 ];
		then
		echo "Attention! No disks found for VM $vid"
		#I INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi

	#RESTORED DISK VERIFICATION COUNTER
	if [ $finddisk != $restoredisk ];
	then
		echo "Attention! Inconsistency between available and restored disks VM $vid"
		#I INCREASE THE CONTROL COUNTER AND PROCEED
		controlerror
		#SEND EMAIL REPORT
		echo "Sending report email"
		send_mail
		exit 1
	fi

	#I REMOVE THE VM IN LOCK MODE TO SYNCHRONIZE THE DISKS
	remqemuvmlock $vid

	#ONCE YOU HAVE FINISHED SYNCHRONIZING THE DISKS UNLESS NEW DESCRIPTION
	if [ ${LOGSIMPLE} -eq 0 ];
		then
		#I SET THE DATE IN THE DESCRIPTION TO IDENTIFY THE BACKUP VERSION
		qm set $vid --description $backuptime
		controlstate
		#DISABLE START VM ON BOOT
		qm set $vid --onboot 0
		controlstate
		echo "Disk sync completed"
	else
		#I SET THE DATE IN THE DESCRIPTION TO IDENTIFY THE BACKUP VERSION
		qm set $vid --description $backuptime > /dev/null
		controlstate
		#DISABLE START VM ON BOOT
		qm set $vid --onboot 0 > /dev/null
		controlstate
	fi

}

#START RESTORE
function startrestorevm (){

	for vmid in ${VM[@]}; do
		#START VM CYCLE
	
		#BACKUP TYPE vm|ct
		bktype="vm"
		
		#I SELECT THE BACKUP WITH THE MOST RECENT DATE
		lastbackuptimestamp=$(proxmox-backup-client list --output-format=json-pretty | jq -r '.[] |select(."backup-id" == "'$vmid'" and ."backup-type" == "'$bktype'") | ."last-backup"')

		#CHECK IF THERE ARE BACKUPS
		if [ -z "$lastbackuptimestamp" ]
			then
			echo "Attention! There are no backups to restore for the VM $vmid"
			#I INCREASE THE CONTROL COUNTER AND PROCEED
			controlerror
			#SEND EMAIL REPORT
			echo "Sending report email"
			send_mail
			exit 1
		else
			#I CONVERT THE TIMESTAMP INTO THE DATE TO BE USED FOR THE RESTORE
			lastbackuptime=$(date +"%Y-%m-%dT%H:%M:%SZ" -ud @$lastbackuptimestamp )
			
			#CHECK IF THE VM IS PRESENT
			vmfind=$(pvesh get /cluster/resources --output-format=json-pretty | jq -r '.[] | select(."vmid" == '$vmid')')
			if [ -z "$vmfind" ]
				then
				#THERE IS NO VM PRESENT. I PROCEED WITH THE RESTORE
				if [ ${LOGSIMPLE} -eq 0 ];
					then
					echo "The VM $vmid is not present, I proceed with the complete restore"
				fi
				#START RECOVERY FUNCTION
				restorevm $bktype $vmid $lastbackuptime
				if [ ${LOGSIMPLE} -eq 1 ];
					then
					echo "The VM $vmid has been replicated"
				fi
			else
				#THE VM IS ALREADY PRESENT
				if [ ${LOGSIMPLE} -eq 0 ];
					then
					echo "The VM $vmid is already present, check if needs to be updated"
				fi
				
				#EXCEPT THE CURRENT DESCRIPTION BY REMOVING THE ADDITIONAL CHARACTERS INSERTED BY QEMU
				curdesc=$(qm config $vmid | grep '^description: '| awk '{$1=""}1'| sed 's/ //'| sed 's/%3A/:/g')
				#CHECK IF THE DESCRIPTION HAS BEEN SAVED CORRECTLY
				if [ -z "$curdesc" ];
					then
					echo "Attention! Problem recovering the replica version in the description for VM $vmid"
					#I INCREASE THE CONTROL COUNTER AND PROCEED
					controlerror
					#SEND EMAIL REPORT
					echo "Sending report email"
					send_mail
					exit 1
				fi
				
				#CHECK THAT THE DESTINATION VM IS NOT LOCKED
				curlock=$(qm config $vmid | grep '^lock: '| awk '{$1=""}1'| sed 's/ //'| sed 's/%3A/:/g')
				#CHECK IF THE LOCK VALUE EXISTS
				if [[ ! -z "$curlock" ]];
					then
					echo "Attention! Problem on the VM $vmid is in lock mode"
					#I INCREASE THE CONTROL COUNTER AND PROCEED
					controlerror
					#SEND EMAIL REPORT
					echo "Sending report email"
					send_mail
					exit 1
				fi
				
				#echo "I verify that the backup is up to date"
				if [ $lastbackuptime != $curdesc ]
					then
					#THE CURRENT VM HAS A DIFFERENT DATE
					if [ ${LOGSIMPLE} -eq 0 ];
						then
						echo "The current VM $vmid has a different date $curdesc instead of $lastbackuptime"
					fi
					#CHECK IF THE VM IS RUNNING
					vmstatus=$(pvesh get /cluster/resources --output-format=json-pretty | jq -r '.[] | select(."vmid" == '$vmid')| ."status"')
					#CHECK IF THE STATUS HAS BEEN SAVED CORRECTLY
					if [ -z "$vmstatus" ];
						then
						echo "Attention! Problem recovering the status for VM $vmid"
						#INCREASE THE CONTROL COUNTER AND PROCEED
						controlerror
						#SEND EMAIL REPORT
						echo "Sending report email"
						send_mail
						exit 1
					fi
					if [ $vmstatus == "running" ]
						then
							#GET ERROR BECAUSE IT STARTED
							echo "Attention! Error the VM $vmid is in running state "
							#INCREASE THE CONTROL COUNTER AND PROCEED
							controlerror
							#SEND EMAIL REPORT
							echo "Sending report email"
							send_mail
							exit 1
					fi

					#CHECK WHETHER TO DESTROY THE MACHINE OR SYNC THE DISKS
					if [ ${SYNCDISK} -eq 0 ];
						then
						#START THE DESTRUCTION OF THE VM
						if [ ${LOGSIMPLE} -eq 0 ];
							then
							echo "I start destroying the VM $vmid"
							qm destroy $vmid --skiplock true --purge true
							controlstate
						else
							qm destroy $vmid --skiplock true --purge true > /dev/null
							controlstate
						fi

						#START RECOVERY FUNCTION
						restorevm $bktype $vmid $lastbackuptime
						
					else
						#MAKE SURE THAT THE FILESYSTEM SNAPSHOT NEEDS TO BE DONE
						if [ ! ${SYNCDISKSNAP} -eq 0 ];
							then
							if [ ${LOGSIMPLE} -eq 0 ];
								then
								echo "Starting snapshot creation process"
								takesnap $vmid $curdesc $lastbackuptime
								echo "End of snapshot creation process"
							else
								takesnap $vmid $curdesc $lastbackuptime > /dev/null
							fi
						fi
						if [ ${LOGSIMPLE} -eq 0 ];
								then
								#START DISK SYNC
								syncdiskvm $bktype $vmid $lastbackuptime
							else
								#START DISK SYNC
								syncdiskvm $bktype $vmid $lastbackuptime > /dev/null
							fi
					fi

				else
					#THE CURRENT VM HAS THE SAME DATE
					if [ ${LOGSIMPLE} -eq 0 ];
						then
						echo "The VM $vmid is already present and is updated"
					fi
				fi
				#echo "Fine cliclo modifica vm $vmid"
				if [ ${LOGSIMPLE} -eq 1 ];
					then
					echo "The VM $vmid has been updated"
				fi
			fi
			
		fi
	done
}

#----------------------------------------------------------------------------------#
################################### START SCRIPT ###################################
#----------------------------------------------------------------------------------#

#CHECK IF THE DESTINATION DIRECTORY EXISTS
controldir ${LOGDIR} > /dev/null

echo "Start vm replication" >${LOG} 2>${ELOG}
echo "`date +%Y/%m/%d-%H:%M:%S`" >>${LOG} 2>>${ELOG}

#I MAKE SURE THAT THE JQ PROGRAM IS INSTALLED, OTHERWISE I EXIT
controljq  >>${LOG} 2>>${ELOG}

#START RESTORE
startrestorevm >>${LOG} 2>>${ELOG}

#END REPLICATION
echo "End of replication procedure" >>${LOG} 2>>${ELOG}
echo "`date +%Y/%m/%d-%H:%M:%S`" >>${LOG} 2>>${ELOG}

#SEND EMAIL REPORT
echo "Sending report email" >>${LOG} 2>>${ELOG}
send_mail >>${LOG} 2>>${ELOG}

#----------------------------------------------------------------------------------#
################################### END SCRIPT ###################################
#----------------------------------------------------------------------------------#