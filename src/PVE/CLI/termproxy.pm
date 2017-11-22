package PVE::CLI::termproxy;

use strict;
use warnings;

use PVE::RPCEnvironment;
use PVE::CLIHandler;
use PVE::JSONSchema qw(get_standard_option);
use PVE::AccessControl;
use PVE::PTY;
use IO::Select;
use IO::Socket::IP;

use base qw(PVE::CLIHandler);

use constant MAX_QUEUE_LEN => 16*1024;

sub setup_environment {
    PVE::RPCEnvironment->setup_default_cli_env();
}

sub listen_and_authenticate {
    my ($port, $timeout) = @_;

    my $params = {
	Listen => 1,
	ReuseAddr => 1,
	Proto => &Socket::IPPROTO_TCP,
	GetAddrInfoFlags => 0,
	LocalAddr => 'localhost',
	LocalPort => $port,
    };

    my $socket = IO::Socket::IP->new(%$params) or die "failed to open socket: $!\n";

    alarm 0;
    local $SIG{ALRM} = sub { die "timed out waiting for client\n" };
    alarm $timeout;
    my $client = $socket->accept; # Wait for a client
    alarm 0;
    close($socket);

    my $queue;
    my $n = sysread($client, $queue, 4096);
    if ($n && $queue =~ s/^([^:]+):([^:]+):(.+)\n//) {
	my $user = $1;
	my $path = $2;
	my $ticket = $3;

	die "authentication failed\n"
	    if !PVE::AccessControl::verify_vnc_ticket($ticket, $user, $path);

	die "aknowledge failed\n"
	    if !syswrite($client, "OK");

    } else {
	die "malformed authentication string\n";
    }

    return ($queue, $client);
}

sub run_pty {
    my ($cmd, $webhandle, $queue) = @_;

    foreach my $k (keys %ENV) {
	next if $k eq 'PATH' || $k eq 'USER' || $k eq 'HOME' || $k eq 'LANG' || $k eq 'LANGUAGE';
	next if $k =~ m/^LC_/;
	delete $ENV{$k};
    }

    $ENV{TERM} = 'xterm-256color';

    my $pty = PVE::PTY->new();

    my $pid = fork();
    die "fork: $!\n" if !defined($pid);
    if (!$pid) {
	$pty->make_controlling_terminal();
	exec {$cmd->[0]} @$cmd
	    or POSIX::_exit(1);
    }

    $pty->set_size(80,20);

    read_write_loop($webhandle, $pty->master, $queue, $pty);

    $pty->close();
    waitpid($pid,0);
    exit(0);
}

sub read_write_loop {
    my ($webhandle, $cmdhandle, $queue, $pty) = @_;

    my $select = new IO::Select;

    $select->add($webhandle);
    $select->add($cmdhandle);

    my @handles;

    # we may have already messages from the first read
    $queue = process_queue($queue, $cmdhandle);

    my $timeout = 5*60;

    while($select->count && scalar(@handles = $select->can_read($timeout))) {
	foreach my $h (@handles) {
	    my $buf;
	    my $n = $h->sysread($buf, 4096);

	    if ($h == $webhandle) {
		if ($n && (length($queue) + $n) < MAX_QUEUE_LEN) {
		    $queue = process_queue($queue.$buf, $cmdhandle, $pty);
		} else {
		    return;
		}
	    } elsif ($h == $cmdhandle) {
		if ($n) {
		    syswrite($webhandle, $buf);
		} else {
		    return;
		}
	    }
	}
    }
}

sub process_queue {
    my ($queue, $handle, $pty) = @_;

    my $msg;
    while(length($queue)) {
	($queue, $msg) = remove_message($queue, $pty);
	last if !defined($msg);
	syswrite($handle, $msg);
    }
    return $queue;
}


# we try to remove a whole message
# if we succeed, we return the remaining queue and the msg
# if we fail, the message is undef and the queue is not changed
sub remove_message {
    my ($queue, $pty) = @_;

    my $msg;
    my $type = substr $queue, 0, 1;

    if ($type eq '0') {
	# normal message
	my ($length) = $queue =~ m/^0:(\d+):/;
	my $begin = 3 + length($length);
	if (defined($length) && length($queue) >= ($length + $begin)) {
	    $msg = substr $queue, $begin, $length;
	    if (defined($msg)) {
		# msg contains now $length chars after 0:$length:
		$queue = substr $queue, $begin + $length;
	    }
	}
    } elsif ($type eq '1') {
	# resize message
	my ($cols, $rows) = $queue =~ m/^1:(\d+):(\d+):/;
	if (defined($cols) && defined($rows)) {
	    $queue = substr $queue, (length($cols) + length ($rows) + 4);
	    eval { $pty->set_size($cols, $rows) if defined($pty) };
	    warn $@ if $@;
	    $msg = "";
	}
    } elsif ($type eq '2') {
	# ping
	$queue = substr $queue, 1;
	$msg = "";
    } else {
	# ignore other input
	$queue = substr $queue, 1;
	$msg = "";
    }

    return ($queue, $msg);
}

__PACKAGE__->register_method ({
    name => 'exec',
    path => 'exec',
    method => 'POST',
    description => "Connects a TCP Socket with a commandline",
    parameters => {
	additionalProperties => 0,
	properties => {
	    port => {
		type => 'integer',
		description => "The port to listen on."
	    },
	    'extra-args' => get_standard_option('extra-args'),
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $cmd;
	if (defined($param->{'extra-args'})) {
	    $cmd = [@{$param->{'extra-args'}}];
	} else {
	    die "No command given\n";
	}

	my ($queue, $handle) = listen_and_authenticate($param->{port}, 10);

	run_pty($cmd, $handle, $queue);

	return undef;
    }});

our $cmddef = [ __PACKAGE__, 'exec', ['port', 'extra-args' ]];

1;
