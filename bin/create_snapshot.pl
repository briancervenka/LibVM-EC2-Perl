#!/usr/bin/perl

# An example of creating a data snapshots
# Steps:
#     1. Provision a new server.
#     2. Create new data volume, attach and mount it.
#     3. Rsync the indicated data over
#     4. Unmount the volume, detach it.
#     5. Save the snapshot.
#     6. Delete the volume
#     7. Terminate the server.

use strict;
use VM::EC2;
use Getopt::Long;
use File::Find;
use File::Basename 'basename';
use constant GB => 1_073_741_824;

my($Snapshot_name,$Filesystem,$Image,$Type,$Username,$Access_key,$Secret_key);
GetOptions('snapshot=s'    => \$Snapshot_name,
	   'filesystem=s'  => \$Filesystem,
	   'image=s'       => \$Image,
	   'username=s'    => \$Username,
	   'type=s'        => \$Type,
	   'access_key=s'  => \$Access_key,
	   'secret_key=s'  => \$Secret_key) or die <<USAGE;
Usage: create_snapshot.pl [options] files/directories to copy...
Rsync the indicated files and directories to Amazon EC2 and store
in a named EBS snapshot. Snapshot will be incrementally updated
if it already exists. The Version tag will be updated.

This will use the default EC2 endpoint URL unless environment variable
EC2_URL is set.

Options:
      --snapshot    Snapshot name (required)
      --access_key  EC2 access key
      --secret_key  EC2 secret key
      --image       Server AMI ID (defaults to ami-ccf405a5, Ubuntu Maverick 32bit)
      --type        Server type (defaults to m1.small)
      --username    Username for logging into instance ("ubuntu")
      --filesystem  Type of filesystem to create (bfs,cramfs,ext*,minix,ntfs,vfat,msdos).
                    Anything with a /sbin/mkfs.* executable on the server side will work.
                    Defaults to ext4.
USAGE
    ;

#setup defaults
$ENV{EC2_ACCESS_KEY} = $Access_key if defined $Access_key;
$ENV{EC2_SECRET_KEY} = $Secret_key if defined $Secret_key;
$Filesystem        ||= 'ext4';
$Image             ||= 'ami-ccf405a5';
$Type              ||= 'm1.small';
$Username          ||= 'ubuntu';

$Snapshot_name or die "Please provide a snapshot name. Run create_snapshot.pl -h for help.\n";
my @locations    = @ARGV;

# These are variables that contain EC2 objects that need to be destroyed
# when script is done.
my ($ec2,$KeyPair,$KeyFile,$Group,$Volume,$Instance);

eval {

    $ec2 = VM::EC2->new() or die "Can't create new VM::EC2";

# find how large a volume we'll need.
    my $bytes_needed = 0;
    find(sub {$bytes_needed += -s $_},@locations);

# add 15% overhead for filesystem
    $bytes_needed *= 1.15;

# and convert to GB
    my $gb = int(0.5+$bytes_needed/GB);
    $gb    = 1 if $gb < 1;

# Provision the volume
    my($volume,$needs_resize) = provision_volume($gb,$Snapshot_name);
    $Volume = $volume;

# Create a temporary key for ssh'ing
    my $keypairname = basename($0)."_$$";
    $KeyFile        = File::Spec->catfile(File::Spec->tmpdir,"$keypairname.PEM");
    $KeyPair        = $ec2->create_key_pair($keypairname);
    my $private_key = $KeyPair->privateKey;
    open my $k,'>',$KeyFile or die "Couldn't create $KeyFile: $!";
    chmod 0600,$KeyFile   or die "Couldn't chmod  $KeyFile: $!";
    print $k $private_key;
    close $k;

# Create a temporary security group for ssh'ing
    $Group          = $ec2->create_security_group(-name => basename($0)."_$$") or die $ec2->error_str;
    $Group->authorize_incoming(-protocol   => 'tcp',
			       -port       => 'ssh');

# Provision an instance in the same availability zone
    my $zone        = $Volume->availabilityZone;
    $Instance       = $ec2->run_instances(-image_id => $Image,
					  -zone     => $zone,
					  -key_name => $KeyPair,
					  -security_group => $Group) or die $ec2->error_str;
    $ec2->wait_for_instances($Instance);
    $Instance->current_status eq 'running'      or die "Instance $Instance, status = ",$Instance->current_status;
    
    my $device = unused_device()                or die "Couldn't find suitable device to attach";
    
    my $s = $Instance->attach_volume($Volume=>$device)  or die "Couldn't attach $Volume to $Instance via $device";
    $ec2->wait_for_attachments($s)                      or die "Couldn't attach $Volume to $Instance via $device";
    $s->current_status eq 'attached'                    or die "Couldn't attach $Volume to $Instance via $device";

    if ($needs_resize) {
	die "Sorry, but can only resize ext volumes " unless $Filesystem =~ /^ext/;
	ssh('sudo /sbin/resize2fs $device');
    }

    ssh('sudo mkdir -p /mnt/transfer; sudo mount $device /mnt/transfer; sudo chown $Username /mnt/transfer');
    my $Host = $Instance->dnsName;
    system "rsync -Ravz -e'ssh -i $KeyFile -l $Username' @locations $Host:/mnt/transfer";

    ssh('sudo umount /mnt/transfer');
    $Instance->detach_volume($Volume);

    # snapshot stuff
    my $version = 1;
    if (my $snap = $Volume->from_snapshot) {
	$version = $snap->tags->{Version} || 0;
	$version++;
    }
    my $snap = $Volume->create_snapshot($Snapshot_name);
    $snap    = $snap->add_tags(Version => $version);
    print "Created snap $snap\n";
};

warn $@ if $@;
cleanup();

exit 0;

sub ssh {
    my $cmd   = shift;
    $Instance or die "No instance running!";
    $KeyFile  or die "No key file defined!";
    my $ip      = $Instance->dnsName;
    my @result  = `ssh -i $KeyFile -l $Username $cmd`;
    chomp(@result);
    return @result;
}

sub unused_device {
    my %devices = map {$_=>1} ssh('ls /dev/sd[a-z]* /dev/xvd[a-z]*');
    my $base    = $devices{'/dev/sda1'}  ? '/dev/sd'
	         :$devices{'/dev/xvda1'} ? '/dev/xvd'
		 :die "can't figure out whether to use /dev/sd or /dev/xvd";
    for my $major ('f'..'p') {
	for my $minor (1..15) {
	    my $candidate = $base.$major.$minor;
	    return $candidate unless $devices{$candidate};
	}
    }
}

sub provision_volume {
    my ($size,$snapshot_name)  = @_;
    my @zones = $ec2->describe_availability_zones({state=>'available'});
    my $zone  = $zones[rand @zones];

    my @snaps = sort {$b->startTime <=> $a->startTime} $ec2->describe_snapshots(-owner  => $ec2->account_id,
										-filter => {description=>$snapshot_name});
    if (@snaps) {
	my $snap = $snaps[0];
	my $s    = $size > $snap->volumeSize ? $size : $snap->volumeSize;
	return $snap->create_volume(-availability_zone=>$zone,
				    -size             => $s);
    } else {
	return $ec2->create_volume(-availability_zone=>$zone,
				   -size             =>$size);
    }
}

sub cleanup {
    return unless $ec2;
    $ec2->delete_key_pair($KeyPair) if $KeyPair;
    $Instance->terminate()          if $Instance;
    $ec2->delete_volume($Volume)    if $Volume;
    unlink $KeyFile                 if -e $KeyFile;
}
