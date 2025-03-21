css_initialize() {
   #Run speedtest and apply cake settings
   /jffs/scripts/cake-speedsync/cake-speedsync.sh

   #Delete cron job to avoid duplicate
   cru d cake-speedsync

   #Re-add cron job
   #Run every 2 hours from 7:00 AM to 11:00 PM
   cru a cake-speedsync "0 7-23/2 * * * /jffs/scripts/cake-speedsync/cake-speedsync.sh"   
}

css_preserve_cake () {
   
   css_cake_cmd #Save current cake settings. Thes settings will be preserve. Only the bandwidth and rtt will be updated later

   if [ "$(wc -c < cake.cmd)" -eq 0]; then
      #Cake is disabled. Enable with default value. Speed will update once cake-speedsync runs
      tc qdisc replace dev eth0 root cake bandwidth 1000mbit diffserv3 dual-srchost nat nowash no-ack-filter split-gso rtt 100ms noatm overhead 34 mpu 88
      tc qdisc replace dev ifb4eth0 root cake bandwidth 1000mbit besteffort dual-dsthost nat wash ingress no-ack-filter split-gso rtt 100ms noatm overhead 34 mpu 88
      css_cake_cmd
   fi
}

css_cake_cmd() {
   cd /jffs/scripts/cake-speedsync/ || exit 1

   #construct command for eth0
   cmd=$(tc qdisc | awk '/dev eth0/ && /bandwidth/' | grep -oE 'dev*.*') 
   echo $cmd > cake.cmd

   #construct command for ifb4eth0
   cmd=$(tc qdisc | awk '/dev ifb4eth0/ && /bandwidth/' | grep -oE 'dev*.*')
   echo $cmd >> cake.cmd   
}

css_status () {
   echo -e "\n[DSCP RULES - Force gaming ports to VOICE Tin"
   echo  "  Active DSCP Rule:"

   ipt="$(iptables -t mangle -L --line-numbers | grep -E "Chain|DSCP")"

   css_check_null "$ipt" "WARNING: Rules not setup. If ISP is stripping DSCP tags, all packets will fall under besteffort. Run /jffs/scripts/services-start and check again"

   echo -e "\n\n[CRON JOB - SCHEDULE - Make sure cake is re-adjusted every n hours]"
   echo  "  Active Cron Entry: "

   cronj=$(crontab -l | grep cake-speedsync.sh)

   css_check_null "$cronj" "WARNING: Crontab entry is missing. Run /jffs/scripts/services-start and check again"

   echo -e "\n\n[CAKE SETTINGS]"
   echo  "  Active CAKE Setting:"

   tccake=$(tc qdisc | grep cake)

   css_check_null "$tccake" "WARNING: CAKE is not currently active. Run /jffs/scripts/services-start or /jffs/scripts/cake-speedsync/cake-speedsync.sh"

   echo -e "\n  cake-speedsync:"

   dyntclog=$(cat /jffs/scripts/cake-speedsync/cake-ss.log | tail -3)
   lastrun=$(cat /jffs/scripts/cake-speedsync/cake-ss.log | tail -3 | head -1)

   uploadSpd=$(echo "$dyntclog" | grep -oE 'dev eth0 root .*' | grep -oE '[0-9]+Mbit')
   downloadSpd=$(echo "$dyntclog" | grep -oE 'dev ifb4eth0 root .*' | grep -oE '[0-9]+Mbit')

   css_check_null "" "last run: $lastrun upload bandwidth:$uploadSpd download bandwidth:$downloadSpd"
   echo -e "\n"
}

css_check_null () {
   if [ -z "$1" ]; then
      echo "$2" | sed 's/^/       /'
   else
      echo "$1" | sed 's/^/       /'
   fi
}

css_qos_udp () {
   $proto="udp"
   $port=$1
   $prio=$2
   $ip=$3

   css_pkt_qos $ip $port $prio $proto
}

css_qos_tcp () {
   $proto="tcp"
   $port=$1
   $prio=$2
   $ip=$3

   css_pkt_qos $ip $port $prio $proto   
}

css_qos_refresh () {
   awk '{print $1, $2, $3, $4}' /jffs/scripts/cake-speedsync/qosports 2>/dev/null | while read -r ip port tag protocol; do
   css_pkt_qos $ip $port $tag $protocol; done 

}

css_pkt_qos () {
   ip=$1
   port=$2

   if [ -z "$3" ]; then
      dscptag="EF" #If $2 is blank set highest priority
   else
      case "$3" in
         1) dscptag="EF" ;;  #Highest
         2) dscptag="CS5" ;; #High
         3) dscptag="CS0" ;; #Normal
         4) dscptag="CS1" ;; #Low
         *) dscptag="EF" ;;  
      esac
   fi
   
   if [ -z "$4" ]; then
      proto="udp"
   else
      proto="$4"
   fi

   cmd="iptables -t mangle -%s %s -p $proto -%s $ip --%s $port -j DSCP --set-dscp-class $dscptag"
   
   #Remove first if existing then re-apply rule - prevent duplicate entries and cluttering iptables
   for mode in "D" "A"; do
      for chain in "FORWARD" "POSTROUTING"; do
         case "$chain" in
            FORWARD) 
               pmatch="dport"
               imatch="d"
               ;;
            POSTROUTING)
               pmatch="sport"
               imatch="s"
               ;;
         esac

         if [[ "$mode" == "D" ]]; then
            eval $(printf "$cmd 2>/dev/null" "$mode" "$chain" "$imatch" "$pmatch")
         else
            eval $(printf "$cmd" "$mode" "$chain" "$imatch" "$pmatch")
         fi         
      done
   done

   #Record ports for re-applying iptables on reboot
   rm -f /jffs/scripts/cake-speedsync/qosports
   iptables -t mangle -S | awk '/PREROUTING/ && /DSCP/ {print $4, $10, $NF, $6}' | while read -r xip xport xhextag xproto; do
      case "$xhextag" in
         0x2e) xtag="1";;
         0x28) xtag="2";;
         0x00) xtag="3";;
         0x08) xtag="4";;
         *) xtag="3";;
      esac
      echo "$ip $xport $xtag $xproto" >> /jffs/scripts/cake-speedsync/qosports; done
   
}