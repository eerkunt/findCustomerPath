#
#
# findCustomerPath  -    This script initiates a discovery from a device throught whole network
#                        trailing all available customer related VLANs
#
# Author            Emre Erkunt
#                   (emre.erkunt@superonline.net)
#
# History :
# -----------------------------------------------------------------------------------------------
# Version               Editor          Date            Description
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
# 0.0.1_AR              EErkunt         20141121        Initial ALPHA Release
# 0.0.2                 EErkunt         20141223        First live release
# 0.0.3                 EErkunt         20141223        Fixed a problem about Cisco UPE/PE Devices
# 0.0.4                 EErkunt         20141223        Fixed a problem about auto-updater
# 0.0.5                 EErkunt         20141223        Fixed a problem about vlan discovery
# 0.0.6                 EErkunt         20141224        Added empty lines in CSV output
#                                                       Fixed some problems on Huawei Switches
#                                                       Again fixed a problem about auto-updater
# 0.0.7                 EErkunt         20141225        Added Huawei switch discovery 
# 0.0.8                 EErkunt         20141226        Re-structured the whole auto-updater !!
# 0.0.9                 EErkunt         20150107        Enhanced the regex for description matching
# 0.1.0                 EErkunt         20150115        Asks for password if not used -p parameter
# 0.1.1                 EErkunt         20150115        Asks for customer and backbone passwords
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
#
# Needed Libraries
#
use threads;
use threads::shared;
use Getopt::Std;
use Net::Telnet;
use Graph::Easy;
use List::Util qw(max min);
use LWP::UserAgent;
use HTTP::Headers;
use LWP::Simple;
use Term::ReadPassword::Win32;

my $version     = "0.1.1";
my $arguments   = "u:p:U:P:i:ghvo:nq";
my $MAXTHREADS	= 15;
my $time = time();
getopts( $arguments, \%opt ) or usage();
if ( $opt{q} ) {
	$opt{debug} = 1;		# Set this to 1 to enable debugging
}
$| = 1;
print "findCustomerPath v".$version;
usage() if ( !$opt{u} or !$opt{U} or !$opt{i} );
usage() if ( $opt{h} );
$opt{o} = "OUT_".$ip."_".$time unless ($opt{o});
$opt{t} = 2 unless $opt{t};	
my @targets;
my @ciNames;

my $svnrepourl  = "http://10.34.219.5/repos/scripts/findCustomerPath/"; # Do not forget the last /
my $SVNUsername = "l2sup";
my $SVNPassword = "Nz7149n!";
my $SVNScriptName = "findCustomerPath.pl";
my $SVNFinalEXEName = "fcp";

$ua = new LWP::UserAgent;
my $req = HTTP::Headers->new;

unless ($opt{n}) {
	#
	# New version checking for upgrade
	#
	$req = HTTP::Request->new( GET => $svnrepourl.$SVNScriptName );
	$req->authorization_basic( $SVNUsername, $SVNPassword );
	my $response = $ua->request($req);
	my $publicVersion;
	my $changelog = "";
	my $fetchChangelog = 0;
	my @responseLines = split(/\n/, $response->content);
	foreach $line (@responseLines) {
		if ( $line =~ /^# Needed Libraries/ ) { $fetchChangelog = 0; }
		if ( $line =~ /^my \$version     = "(.*)";/ ) {
			$publicVersion = $1;
		} elsif ( $line =~ /^# $version                 \w+\s+/g ) {
			$fetchChangelog = 1;
		} 
		if ( $fetchChangelog eq 1 ) { $changelog .= $line."\n"; }
	}
	if ( $version ne $publicVersion and length($publicVersion)) {		# SELF UPDATE INITIATION
		print "\nSelf Updating to v".$publicVersion.".";
		$req = HTTP::Request->new( GET => $svnrepourl.$SVNFinalEXEName.'.exe' );
		$req->authorization_basic( $SVNUsername, $SVNPassword );
		if($ua->request( $req, $SVNFinalEXEName.".tmp" )->is_success) {
			print "\n# DELTA CHANGELOG :\n";
			print "# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n";
			print "# Version               Editor          Date            Description\n";
			print "# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n";
			print $changelog;
			open(BATCH, "> upgrade".$SVNFinalEXEName.".bat");
			print BATCH "\@ECHO OFF\n";
			print BATCH "echo Upgrading started. Ignore process termination errors.\n";
			print BATCH "sleep 1\n";
			print BATCH "taskkill /F /IM ".$SVNFinalEXEName.".exe > NULL 2>&1\n";
			print BATCH "sleep 1\n";
			print BATCH "ren ".$SVNFinalEXEName.".exe ".$SVNFinalEXEName."_to_be_deleted  > NULL 2>&1\n";
			print BATCH "copy /Y ".$SVNFinalEXEName.".tmp ".$SVNFinalEXEName.".exe > NULL 2>&1\n";
			print BATCH "del ".$SVNFinalEXEName.".tmp > NULL 2>&1\n";
			print BATCH "del ".$SVNFinalEXEName."_to_be_deleted > NULL 2>&1\n";
			print BATCH "del NULL\n";
			print BATCH "echo All done. Please run the ".$SVNFinalEXEName." command once again.\n\n";
			close(BATCH);
			print "Initiating upgrade..\n";
			sleep 1;
			exec('cmd /C upgrade'.$SVNFinalEXEName.'.bat');
			exit;
		} else {
			print "Can not retrieve file. Try again later. You can use -n to skip updating\n";
			exit;
		}
	} else {
		print " ( up-to-date )\n";
	}
} else {
	print " ( no version check )\n";
}

print "Verbose mode ON\n" if ($opt{v});

#
# Main Loop
#
# Beware, dragons beneath here! Go away.
#
# Get the Password from STDIN 
#
$opt{p} = read_password('Enter your customer switch password : ') unless ($opt{p});
$opt{P} = read_password('Enter your backbone switch password : ') unless ($opt{P});


print "Starting path discovery.\n" if ($opt{v});
$opt{t} = $MAXTHREADS	if ($opt{t} > $MAXTHREADS);

my @running = ();
my @Threads;


my $fh;
my $csvFileName = $opt{o}.".csv";
open($fh, "> ".$csvFileName) or die ("Can not write on $opt{o}.");
print $fh "\"IP Address\";\"VLAN ID\";\"Description\"\n";

our $CSV = "";
my @DATA :shared;
my @STDOUT;
my %nodes :shared;
my %fill :shared;
my %edges :shared;
our $graph = Graph::Easy->new();
my @targets;
my @objects;

print "Initial discovery on $opt{i}..\n" if ($opt{v});

our %tree;
our %obj;

my @initVLANList = findVLAN( $opt{i}, \%opt );

if ( scalar @initVLANList eq 1 ) {
	if ( $initVLANList[0] eq 0 ) {
		print "Can not discover VLANs!\n";
		exit;
	}
}


print "VLAN IDs : ";
foreach my $vlanID ( @initVLANList ) {
	print "[ $vlanID ] ";
}
print "\n";


if ( scalar @initVLANList gt 0 ) {
	foreach my $vlanID ( @initVLANList ) {
		print "\nVLAN: $vlanID\n";
		findNeighbor($opt{i}, $vlanID, \%opt);
	}
} else {
	print "Can not find any VLANs to discover.\n";
}

$graph->output_format('svg');
$graph->timeout(600);

print "\nRe-organizing the graph"  if($opt{v});
my $max = undef;

$graph->randomize();
my $seed = $graph->seed(); 

$graph->layout();
$max = $graph->score();

for (1..10) {
  $graph->randomize();                  # select random seed
  $graph->catch_warnings(1);			# Disable warnings
  $graph->layout();                     # layout with that seed
  if ($graph->score() > $max) {
	$max = $graph->score();             # store the new max store
	$seed = $graph->seed();             # and it's seed
	print "." if ($opt{v});
  }
}

# redo the best layout
if ($seed ne $graph->seed()) {
  $graph->seed($seed);
  $graph->layout();
  print "." if ($opt{v});
}
print "\n"  if ($opt{v});
 
print "Creating graph.\n"  if($opt{v});
 
my $graphFilename = $opt{o}.".html";
open(GRAPHFILE, "> ".$graphFilename) or die("Can not create graphic file ".$graphFilename);
print GRAPHFILE $graph->output();
close(GRAPHFILE);

print $fh $CSV;
close($fh);

print "\nAll done and saved on $csvFileName";
print " and $graphFilename." if ($opt{g});
print "\n";
print "Process took ".(time()-$time)." seconds.\n"   if($opt{v});

#
# Related Functions
#
sub showDescription( $ $ $ ) {
	my $targetIP = shift;
	my $vlanID = shift;
	my $opt = shift;

	unless ( $graph->node(''.$targetIP.':'.$vlanID.'') ) {
		my $node = $graph->add_node(''.$targetIP.':'.$vlanID.'');
		$node->set_attribute('fontsize', '80%');
		$node->set_attribute('font', 'Arial');
		$node->set_attribute('shape', 'rounded');
	}
	my $node = $graph->node(''.$targetIP.':'.$vlanID.'');
	$node->set_attribute('fill', '#4FE383');
	
	print " => $targetIP ";
	my $vendor;
	print "(!! This is a PE Device! !!)" if ($opt{debug});
	if ( $obj{$targetIP} ) {
		$obj{$targetIP}->close();
		delete $obj{$targetIP};
	}
	
	$obj{$targetIP} = new Net::Telnet ( Timeout => 240 );		# Do not forget to change timeout on new development !!!!!!!!!		
	$obj{$targetIP}->errmode("return");
	if ($obj{$targetIP}->open($targetIP)) {
		$vendor = authenticate( $targetIP, \%{$opt} );
	}
	my @command; my @regex; my @prompt;
	if ( $vendor eq "cisco" ) {
		$prompt[0] = '/#$/';
		$command[0] = 'sh int description | i ".'.$vlanID.'   "';
		$regex[0] = '.*(up|down).*';
	} elsif ( $vendor eq "huawei") {
		$prompt[0] = '/<.*>$/';
		$command[0] = 'display interface description | i \.'.$vlanID;
		$regex[0] = '^(((GE\d*)|(VE\d*)|(Eth\-Trunk[0-9\.]+)).*)';
		$prompt[1] = '/<.*>$/';
		$command[1] = 'dis cur interface Vlanif'.$vlanID.' | i description';
		$regex[1] = 'description (.*)';
	} else {
		print "Can not authenticate on ".$targetIP.".\n";
		return 0;
	}

	print "==> Show Description on PE Device : " if ( $opt{debug} );
	
	my $out = "";
	for(my $a=0;$a<scalar @command;$a++) {
		print "[$a] Running CMD : $command[$a] with prompt $prompt[$a] ( filter with : $regex[$a] )\n"  if ( $opt{debug} );
		my @return = $obj{$targetIP}->cmd(String => $command[$a], Prompt => $prompt[$a]) or die($object->errmsg);
		foreach my $line (@return) {
			my $tmpRegex = $regex[$a];
			if ( $line =~ /$tmpRegex/ ) {
				print "[$a] Match Regex : $1\n" if ( $opt{debug} );
				$out .= $line;
				chomp($line);
				$CSV .= "\"".$targetIP."\";\"".$vlanID."\";\"".$line."\"\n"; 
			}
		}	
	}
	
	if ( !length($out) ) {
		$CSV .= "\"".$targetIP."\";\"".$vlanID."\";\"N\/A\"\n"; 
	}
	
	print "[PE desc : " if ($opt{debug});
	print "\n\n-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n".$out."-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n";
	print "] " if ($opt{debug});
	return 0;
}

sub findPE( $ $ $ ) {
	my $targetIP = shift;
	my $vlanID = shift;
	my $opt = shift;

	unless ( $graph->node(''.$targetIP.':'.$vlanID.'') ) {
		my $node = $graph->add_node(''.$targetIP.':'.$vlanID.'');
		$node->set_attribute('fontsize', '80%');
		$node->set_attribute('font', 'Arial');
		$node->set_attribute('shape', 'rounded');
	}
	my $node = $graph->node(''.$targetIP.':'.$vlanID.'');
	$node->set_attribute('fill', '#A5C1F2');
	
	my $vendor;
	print "(!! This is a UPE Device! !!)" if ($opt{debug});
	if ( $obj{$targetIP} ) {
		$obj{$targetIP}->close();
		delete $obj{$targetIP};
	}
	
	print " => $targetIP ";
	$obj{$targetIP} = new Net::Telnet ( Timeout => 240 );		# Do not forget to change timeout on new development !!!!!!!!!		
	$obj{$targetIP}->errmode("return");
	if ($obj{$targetIP}->open($targetIP)) {
		$vendor = authenticate( $targetIP, \%{$opt} );
	}
	my @command; my @regex; my @prompt;
	if ( $vendor eq "cisco" ) {
		$prompt[0] = '/#$/';
		my $prefix;
		if ( length($vlanID) eq 3 ) { $prefix = 100; } else { $prefix = 10; }
		$command[0] = 'sh run | i '.$prefix.''.$vlanID;
		$regex[0] = '\s*\w+\s*(\d*\.\d*\.\d*\.\d*) '.$prefix.''.$vlanID.' .*';	
	} elsif ( $vendor eq "huawei") {
		$prompt[0] = '/<.*>$/';
		if ( length($vlanID) eq 3 ) { $prefix = 100; } else { $prefix = 10; }
		$command[0] = 'display cur | i '.$prefix.''.$vlanID;	
		$regex[0] = '\w+ \w+ (\d*\.\d*\.\d*\.\d*) '.$prefix.''.$vlanID;			
	} else {
		print "Can not authenticate on ".$targetIP.".\n";
		return 0;
	}

	print "==> PE Discovery : " if ( $opt{debug} );
	
	my $peIP = runRemoteCommand( $obj{$targetIP}, $command[0], $prompt[0], $regex[0] );
	print "[PE IP : $peIP] " if ($opt{debug});
	
	if ( $peIP ) {
		unless ($graph->edge(''.$targetIP.':'.$vlanID.'', ''.$peIP.':'.$vlanID.'')) {
			my $edge = $graph->add_edge(''.$targetIP.':'.$vlanID.'', ''.$peIP.':'.$vlanID.'');
			# $edge->set_attribute('arrowstyle', 'none');
			$edge->set_attribute('label', 'xconnect');
		}
	}
	
	return $peIP;
}

sub runRemoteCommand( $ $ $ $ ) {
	my $object = shift;
	my $cmd = shift;
	my $prompt = shift;
	my $regex = shift;
	
	print "Running CMD : $cmd with prompt $prompt ( filter with : $regex )\n"  if ( $opt{debug} );
	my @return = $object->cmd(String => $cmd, Prompt => $prompt) or die($object->errmsg);
	foreach my $line (@return) {
		# print "RETURN LINE : $line";
		if ( $line =~ /$regex/ ) {
			print "Match Regex : $1\n" if ( $opt{debug} );
			return $1;
		}
	}	
}

sub findNeighbor() {
	my $targetIP = shift;
	my $vlanID = shift;
	my $opt = shift;
	
	print "\nfindNeighbor( '".$targetIP."', '".$vlanID."' )\n"  if ($opt{debug});
	print "=> $targetIP ";
	unless ( $graph->node(''.$targetIP.':'.$vlanID.'') ) {
		my $node = $graph->add_node(''.$targetIP.':'.$vlanID.'');
		$node->set_attribute('fontsize', '80%');
		$node->set_attribute('font', 'Arial');
		$node->set_attribute('shape', 'rounded');
	}

	$obj{$targetIP} = new Net::Telnet ( Timeout => 240 );		# Do not forget to change timeout on new development !!!!!!!!!		
	$obj{$targetIP}->errmode("return");
	my @command; my @regex; my @prompt;
	my $vendor;
	if ($obj{$targetIP}->open($targetIP)) {
		$vendor = authenticate( $targetIP, \%{$opt} );
		
		if ( $vendor eq "cisco" ) {
			$prompt[0] = '/#$/';
			$command[0] = 'sh run | i ip default';
			$regex[0] = 'ip default-gateway (\d*\.\d*\.\d*\.\d*)';
			
			$command[1] = 'sh arp _RETURN_';
			$regex[1] = 'Internet\s*_RETURN_\s*\d*\s*([0-9a-f\.]+)\s*ARPA.*';
			
			$command[6] = 'sh arp | i _RETURN_ ';
			$regex[6] = 'Internet\s*_RETURN_\s*\d*\s*([0-9a-f\.]+)\s*ARPA.*';
			
			$command[2] = 'sh mac address-table address _RETURN_'; # Deprecated : | i '.$vlanID;
			# $regex[2] = '\d*\s*_RETURN_\s*\w+\s*([A-Za-z\-0-9\/]+)';
			$regex[2] = '.*_RETURN_.*.*((Gi\d*\/\d*)|(Po\d*)|(EthTrunk\-\d*)).*';
			
			$command[3] = 'sh int _RETURN_ | i Members';
			$regex[3] = '  Members in this channel: (Gi\d*\/\d*)\s';
			$command[4] = 'sh cdp ne _RETURN_ det';	
			$command[5] = 'sh lldp neighbors _RETURN_ det';	
		} elsif ( $vendor eq "huawei") {
			$prompt[0] = '/<.*>/';
			$command[0] = 'dis cur | i ip route';
			$regex[0] = ' ip route-static 0\.0\.0\.0 0\.0\.0\.0 (\d*\.\d*\.\d*\.\d*)';
			
			$command[1] = 'disp arp | i _RETURN_';
			$regex[1] = '_RETURN_\s*([0-9a-f\-]+)\s*\d*.*';
			
			$command[6] = 'disp arp | i _RETURN_';
			$regex[6] = '_RETURN_\s*([0-9a-f\-]+)\s*\d*.*';
			
			$command[2] = 'disp mac-address _RETURN_'; 
			$regex[2] = '_RETURN_\s*\d*\/\-\s*((GE\d*\/\d*\/\d*)|(Eth\-Trunk\d*))\s*\w+';
			
			$command[3] = 'dis int _RETURN_ | i Giga';
			$regex[3] = '(GigabitEthernet\d*\/\d*\/\d*)\s\w*\s\d*';
			$command[4] = 'disp lldp neighbor interface _RETURN_';	
			$command[5] = 'disp lldp neighbor interface _RETURN_';	
		} else {
			print "Can not authenticate on ".$targetIP.".\n";
			return 0;
		}
	} else {
		print "Can not connect on ".$targetIP." via TCP 23.\n";
		$targetIP = 0;
	}
	
	if ( $targetIP ) {
		# Find Related Interface
		my $interface;
		print "==> Interface Discovery : " if ( $opt{debug} );
		
		# First find the default GW IP.
		my $dgw = runRemoteCommand( $obj{$targetIP}, $command[0], $prompt[0], $regex[0] );
		print "[DGWIP : $dgw] " if ($opt{debug});
		print ".";
		
		# Then find the MAC address of default GW.
		$command[1] =~ s/_RETURN_/$dgw/g;
		$regex[1] =~ s/_RETURN_/$dgw/g;
		my $macdgw = runRemoteCommand( $obj{$targetIP}, $command[1], $prompt[0], $regex[1] );
		if ( length($macdgw) ne 14 ) {
			$command[6] =~ s/_RETURN_/$dgw/g;
			$regex[6] =~ s/_RETURN_/$dgw/g;
			$macdgw = runRemoteCommand( $obj{$targetIP}, $command[6], $prompt[0], $regex[6] );
		}
		print "[MAC of DGW: $macdgw] " if ($opt{debug});
		print ".";
		
		# At last find related interface against this MAC address on given VLAN;
		$command[2] =~ s/_RETURN_/$macdgw/g;
		$regex[2] =~ s/_RETURN_/$macdgw/g;
		my $interface = runRemoteCommand( $obj{$targetIP}, $command[2], $prompt[0], $regex[2] );
		print "[Interface: $interface] " if ($opt{debug});
		print ".";
		
		# Find neighbors
		my @targets;
		my @cinames;

		# Check if interface is a bonding interface
		if ( $interface =~ /(Po\d*|Eth\-Trunk\d*)/ ) {	
			# Find native interface
			$command[3] =~ s/_RETURN_/$interface/g;
			$interface = runRemoteCommand( $obj{$targetIP}, $command[3], $prompt[0], $regex[3] );
			print "[Native Interface: $interface] " if ($opt{debug});
			print ".";
		}
			
		if ($interface) {	
			# First try CDP
			$command[4] =~ s/_RETURN_/$interface/g;
			if ( $vendor eq "huawei" ) {
				$command[4] =~ s/GE/GigabitEthernet/g;
			}
			print "Running $command[4]\n" if ($opt{debug});
			my @return = $obj{$targetIP}->cmd(String => $command[4], Prompt => $prompt[0] );
			if ( $#return eq 1 ) {
				print ".";
				# CDP Failed ? No problem, try LLDP.
				$command[5] =~ s/_RETURN_/$interface/g;
				print "Running $command[5]\n" if ($opt{debug});
				@return = $obj{$targetIP}->cmd(String => $command[5], Prompt => $prompt[0] );
			}
			foreach my $line (@return) {
				# Device ID: nw_sc_c034_01.34_umrn_cola
				#   IP address: 172.28.168.213
				# print "OUTPUT : $line";
				if ( $line =~ /(System Name:|Device ID:|System name\s*:)\s*(.*)/ ) {
					print "==> Neighbor Discovery on $interface : (CI : $2)\t" if ( $opt{debug} );
					my $tempCI = $2;
					if ( !in_array(\@cinames, $tempCI) ) {
						push(@cinames, $tempCI);
					}
				} elsif ( $line =~ /\s*([IPadres:]+|Management address\s*:) (\d*\.\d*\.\d*\.\d*)/) {
					print "(IP : $2)\n" if ( $opt{debug} );
					my $tempIP = $2;
					if ( !in_array(\@targets, $tempIP) ) {
						push(@targets, $tempIP);
						unless ($graph->node(''.$tempIP.'')) {
							my $node = $graph->add_node(''.$tempIP.':'.$vlanID.'');
							$node->set_attribute('fontsize', '80%');
							$node->set_attribute('font', 'Arial');
							$node->set_attribute('shape', 'rounded');
						}
						
						unless ($graph->edge(''.$targetIP.':'.$vlanID.'', ''.$tempIP.':'.$vlanID.'')) {
							my $edge = $graph->add_edge(''.$targetIP.':'.$vlanID.'', ''.$tempIP.':'.$vlanID.'');
							# $edge->set_attribute('arrowstyle', 'none');
							$edge->set_attribute('label', $interface);
						}
					}
				}
			}
			
			print "Found ".scalar @targets." targets and ".scalar @cinames." CI names.\n" if ( $opt{debug} );
			
			for(my $i=0;$i < scalar @targets; $i++ ) {
				if ( $cinames[$i] =~ /nw_rt.*/ ) {
					my $peIP = findPE( $targets[$i], $vlanID, \%{$opt} );
					if ( $peIP ) {
						showDescription( $peIP, $vlanID, \%{$opt} );
					} else {
						showDescription( $targets[$i], $vlanID, \%{$opt} );
					}
				} else {
					# This target is not a Core switch. So continue on discovering neighbors
					findNeighbor( $targets[$i], $vlanID, \%{$opt});
				}
			}
			
		} else {
			print "No interface found\n" if ( $opt{debug} );
		}
	}
}

sub findVLAN() {
	my $targetIP = shift;
	my $opt = shift;
	my @output;
	
	$obj{$targetIP} = new Net::Telnet ( Timeout => 240 );		# Do not forget to change timeout on new development !!!!!!!!!		
	$obj{$targetIP}->errmode("return");
	my $command; my $ciCMD; my $ciname; 
	if ($obj{$targetIP}->open($targetIP)) {
		my $vendor = authenticate( $targetIP, \%{$opt} );
		my $prompt;
		if ( $vendor eq "cisco" ) {
			$prompt = '/#$/';
			$command = 'sh vlan';
			$ciCMD = 'sh ver';
			
		} elsif ( $vendor eq "huawei") {
			$prompt = '/<.*>$/';
			$command = 'disp vlan';
			$ciCMD = 'disp ver';
			
		} else {
			print "Can not authenticate on ".$targetIP.".\n";
			return 0;
		}
		my @VLANIDs;
		my @return = $obj{$targetIP}->cmd(String => $command, Prompt => $prompt );
		my @ignoreList = ( 1, 996, 1002, 1003, 1004, 1005, 103, 697, 695, 696, 111 );
		
		foreach my $line (@return) {
			if ( $line =~ /^(\d*)\s*.*/ ) {
				if ( !in_array(\@ignoreList, $1) and length($1) ) {
					push(@VLANIDs, $1) unless (in_array(\@VLANIDs, $1));
				}
			}
		}
		print "Found ".scalar @VLANIDs." eligible VLANs on ".$targetIP.".\n" if($opt{debug});

		
		my @return = $obj{$targetIP}->cmd(String => $ciCMD, Prompt => $prompt );
		foreach my $line (@return) {
			if ( $line =~ /^(nw.*) uptime is .*/ ) {
				$ciname = $1;
				print "CI Name : $ciname\n";		
			}
		}
		
		foreach my $vlanid (@VLANIDs) {
			print "[$targetIP] VLANID : ".$vlanid."\n" if($opt{debug});
			$tree{$targetIP}[$vlanid] = $ciname;;
		}		
		disconnect($obj{$targetIP});
		delete $obj{$targetIP};
		return @VLANIDs;
	} else {
		print "Can not connect to ".$opt{i}." on tcp/23.\n";
		return 0;
	}	
}

sub disconnect() {
	my $obj			= shift;
	
	$obj->close();
	return 1;
}

sub authenticate() {
	my $targetIP = shift;
	my $opt = shift;
	
	my @initialCommands;
	my $vendor;
	my $prompt;
	my $timeOut = 5;
	
	if ($obj{$targetIP}->login( Name => $opt{u}, Password => $opt{p}, Prompt => '/#$/', Timeout => $timeOut ) ) {			# Try for Cisco
		print "Logged in Cisco!\n" if ($opt{debug});
		$vendor = "cisco";
		$initialCommands[0] = "terminal length 0";
		$prompt = '/#$/';
	} else {
		print "Cisco login failed. Trying huawei\n" if ( $opt{debug} );
		print "." unless ($opt{debug});
		$obj{$targetIP}->close();
		delete $obj{$targetIP};
		$obj{$targetIP} = new Net::Telnet ( Timeout => 240 );
		$obj{$targetIP}->errmode("return");	
		$obj{$targetIP}->open($targetIP);
		print "." unless ($opt{debug});
		if($obj{$targetIP}->login( Name => $opt{u}, Password => $opt{p}, Prompt => '/<.*>$/', Timeout => $timeOut ) ) { 	# Try for Huawei
			print "Logged in Huawei!\n" if ($opt{debug});
			$vendor = "huawei";
			$initialCommands[0] = "screen-length 0 temporary";
			$prompt = '/<.*>$/';
		} else {
			print "Login with normal user/pass failed. Trying core switch login\n" if ( $opt{debug} );
			$obj{$targetIP}->close();
			delete $obj{$targetIP};
			$obj{$targetIP} = new Net::Telnet ( Timeout => 240 );
			$obj{$targetIP}->errmode("return");
			$obj{$targetIP}->open($targetIP);
			print "." unless ($opt{debug});
			# Might be a Core Switch
			if($obj{$targetIP}->login( Name => $opt{U}, Password => $opt{P}, Prompt => '/#$/', Timeout => $timeOut ) ) {  # Try for Cisco Core Switch
				print "\nLogged in Cisco Core Switch!\n" if ($opt{debug});
				$vendor = "cisco";
				$initialCommands[0] = "terminal length 0";
				$prompt = '/#$/';
			} else {
				$obj{$targetIP}->close();
				delete $obj{$targetIP};
				$obj{$targetIP} = new Net::Telnet ( Timeout => 240 );
				$obj{$targetIP}->errmode("return");
				$obj{$targetIP}->open($targetIP);
				print "." unless ($opt{debug});
				if($obj{$targetIP}->login( Name => $opt{U}, Password => $opt{P}, Prompt => '/<.*>$/', Timeout => $timeOut ) ) {  # Try for Huawei Core Switch
					print "\nLogged in Huawei Core Switch!\n" if ($opt{debug});
					$vendor = "huawei";
					$initialCommands[0] = "screen-length 0 temporary";
					$prompt = '/<.*>$/';
				} else {
					return 0;
				}
			}
		}
	}
	
	# Fixing screen buffering problems
	foreach my $command (@initialCommands) {
		#print "Running '$command' : " if ($opt{debug});
		$obj{$targetIP}->cmd(String => $command, Prompt => $prompt);
		#print "Ok!\n" if ($opt{debug});
	}		
	return $vendor;
}

sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

sub gradient {
    my $min = shift;
	my $max = shift;
	my $num = shift;
	
    my $middle = ( $min + $max ) / 2;
    my $scale = 255 / ( $middle - $min );

    return "FF0000" if $num <= $min;    # lower boundry
    return "00FF00" if $num >= $max;    # upper boundary

    if ( $num < $middle ) {
        return sprintf "FF%02X00" => int( ( $num - $min ) * $scale );
    } else {
        return sprintf "%02XFF00" => 255 - int( ( $num - $middle ) * $scale );
    }
}

sub in_array {
     my ($arr,$search_for) = @_;
     my %items = map {$_ => 1} @$arr; 
     return (exists($items{$search_for}))?1:0;
}
 
sub usage {
	my $usageText = << 'EOF';
	
This script initiates a discovery from a device throught whole network trailing all available customer related VLANs

Author            Emre Erkunt
                  (emre.erkunt@superonline.net)

Usage : fcp [-i IP] [-v] [-u USERNAME] [-p PASSWORD] [-U USERNAME] [-P PASSWORD] -g [-o FILENAME] [-n]

 Parameter Descriptions :
 -u [USERNAME]        Username for customer switch network
 -p [PASSWORD]        Password for customer switch network
 -U [USERNAME]        Username for backbone switch network
 -P [PASSWORD]        Username for backbone switch network
 -o [FILENAME]        Output file                               ( Default OUT_IP_time )
 -i [IP]              The starting IP of discovery process
 -v                   Verbose                                   ( Default OFF )
 -g                   Generate network graph                    ( Default OFF )
 -n                   Skip self auto-update                     ( Default ON )

EOF
	print $usageText;
	exit;
}   # usage()
