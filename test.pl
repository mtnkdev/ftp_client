#!/usr/bin/perl



package PtyPair;

use IO::Handle;
use POSIX qw(O_RDWR O_NOCTTY WEXITSTATUS dup2);
use Fcntl;

# Needed because h2ph desn't generate it
our %sizeof = (
	'int' => length(pack("i!", 0)),
	'signed int' => length(pack("i!", 0)),
	'unsigned int' => length(pack("I!", 0))
);
require "sys/ioctl.ph";



# Open a new pair of terminals
# Return an array of 3 values: (master_filehanle, slave_filehandle, slave_terminal_name)
sub new {
	my $class = shift;
	my $self;

	my $fdm;
	my $fds;
	my $ptsname;

	open($fdm, "+<", "/dev/ptmx") or die("open(/dev/ptmx): $!");

	# Set right permission on the slave terminal (optional on linux)
	_grantpt($fdm);

	# Allow to open the slave
	_unlockpt($fdm) or die("unlockpt: $!");

	# Get the name of the slave
	$ptsname = _ptsname($fdm) or die("ptsname: $!");

	open($fds, "+<", $ptsname) or die("open($ptsname): $!");

	$self->{masterfd} = $fdm;
	$self->{slavefd} = $fds;
	$self->{slavename} = $ptsname;

	bless $self, $class;
	return $self;
}



sub master {
	my $self = shift;
	return $self->{masterfd};
}



sub slave {
	my $self = shift;
	return $self->{slavefd};
}



sub slavename {
	my $self = shift;
	return $self->{slavename};
}



sub close_master {
	my $self = shift;
	close($self->master) or die("close(master): $!");
}



sub close_slave {
	my $self = shift;
	close($self->slave) or die("close(slave): $!");
}



sub close {
	my $self = shift;
	$self->close_slave();
	$self->close_master();
}



sub make_stdin {
	my $self = shift;
	my $fd = $self->slave();

	dup2(fileno($fd), fileno(STDIN)) or die("dup2(STDIN): $!");
	# Remove the default FD_CLOEXEC
	fcntl(STDIN, F_SETFD, 0) or die("fcntl: F_SETFD");
}



sub make_stdout {
	my $self = shift;
	my $fd = $self->slave();

	dup2(fileno($fd), fileno(STDOUT)) or die("dup2(STDOUT): $!");
	# Remove the default FD_CLOEXEC
	fcntl(STDOUT, F_SETFD, 0) or die("fcntl: F_SETFD");
}



sub make_stderr {
	my $self = shift;
	my $fd = $self->slave();

	dup2(fileno($fd), fileno(STDERR)) or die("dup2(STDERR): $!");
	# Remove the default FD_CLOEXEC
	fcntl(STDERR, F_SETFD, 0) or die("fcntl: F_SETFD");
}



##################
# Helper methods #
##################
sub _grantpt {
	my $fd = shift;
	my $pid;

	# Just call /usr/lib/pt_chown with file descriptor 3 beeing the opened
	# master terminal $fd
	$pid = fork();

	die("fork: $!") if ($pid == -1);

	if ($pid == 0) {
		my $fd3;

		dup2(fileno($fd), 3) or die("dup2: $!");

		# Make a filehandle from a file descriptor so we call call fcntl
		$fd3 = IO::Handle->new_from_fd(3, "r+");

		# Remove the default FD_CLOEXEC
		$fd3->fcntl(F_SETFD, 0) or die("fcntl: F_SETFD");

		exec("/usr/lib/pt_chown");
		die("exec(pt_chown): $!");
	} else {
		my @pt_chown_code = (undef, 'EBADF', 'EINVAL',
			'EACCES', 'EXEC', 'ENOMEM');
		wait() or die("wait($pid): $!");
		die("pt_chown: $? (".$pt_chown_code[WEXITSTATUS($?)].")") if ($? != 0);
	}

	return 0;
}



sub _unlockpt {
	my $fd = shift;
	my $unlock = pack("I!", 0);

	ioctl($fd, &TIOCSPTLCK, $unlock) or return undef;

	return $fd;
}



sub _ptsname {
	my $fd = shift;
	my $ptyno = "";

	ioctl($fd, &TIOCGPTN, $ptyno) or return undef;
	$ptyno = unpack("I!", $ptyno);

	return "/dev/pts/$ptyno";
}






package PtyRunner;

use warnings;
use strict;
use Time::HiRes qw(time);


sub new {
	my $class = shift;
	my @args = @_;
	my $self = {};

	$self->{ptyinout} = new PtyPair();
	$self->{ptyerr} = new PtyPair();

	bless $self, $class;
	return $self;
}



sub run {
	my $self = shift;
	my @args = @_;

	my $pid = fork();
	die("fork: $!") if ($pid == -1);

	if ($pid == 0) {
		# TODO une autre paire pour stderr
		$self->{ptyinout}->make_stdin();
		$self->{ptyinout}->make_stdout();
		$self->{ptyerr}->make_stderr();
		$self->{ptyinout}->close();
		$self->{ptyerr}->close();
		exec(@args);
		die("exec $args[0]: $!");
	} else {
		$self->{ptyinout}->close_slave();
		$self->{ptyerr}->close_slave();
	}

	$self->{pid} = $pid;
}



sub send {
	my $self = shift;
	my $str = shift;
	syswrite($self->{ptyinout}->master(), $str) or die("syswrite: $!");
	return 1;
}



# Read a line (until $/ is found) within up to a certain amout of time
sub _recv_line_timed {
	my $fd = shift;
	my $timeout = shift;

	my $start_time = time;
	my $end_time = $start_time + $timeout;
	my ($rin, $rout);
	my $closed = 0;
	my $timeouted = 0;
	my $c = '';
	my $strout = '';

	$rin = "";
	vec($rin, fileno($fd), 1) = 1;

	# Read until \n
	while ($c ne $/) {
		my $nfound;

		my $now = time;
		last if ($now > $end_time);

		$nfound = select($rout = $rin, undef, undef, $end_time - $now);

		# Unexpected error
		die("select: $!") if ($nfound == -1);

		# Timeouted
		if ($nfound == 0) {
			$timeouted = 1;
			last;
		}

		$! = 0;
		my $nread = sysread($fd, $c, 1);

		# fd closed?
		if (!defined($nread)) {
			next if ($!{EAGAIN});
			$closed = 1 if ($!{ECONNRESET});
			last;
		}

		# WTF? Nothing to read but select returned...
		if ($nread == 0) {
			warn "Bug in get_line_timed. select returned without anything to read\n";
			$closed = 1;
			last;
		}

		$strout .= $c;
	}

	#print STDERR $strout."\n";

	return ($strout, $timeouted, $closed);
}



sub recv_line_stderr {
	my $self = shift;
	my ($str, $timeout, $closed) = _recv_line_timed($self->{ptyerr}->master(), 0.3);

	return {str => $str, timeout => $timeout, closed => $closed};
}



sub recv_line_stdout {
	my $self = shift;
	my ($str, $timeout, $closed) = _recv_line_timed($self->{ptyinout}->master(), 0.3);

	return {str => $str, timeout => $timeout, closed => $closed};
}



# Just read what is available
# Wait if there's nothing
sub recv_stdout {
	my $self = shift;
	my $str = undef;
	my $closed = 0;
	my $timeout = 0;

	# TODO select + recv_line_stdout
	my $n = sysread($self->{ptyinout}->master(), $str, 1024);

	if (!defined $n || $n == 0) {
		$closed = 1;
		$str = undef;
	} else {
		# If we read something, give it some time to send the rest of the line
		my $res = $self->recv_line_stdout();
		$str .= $res->{str} if (defined $res->{str});
		$closed = $res->{closed};
		$timeout = $res->{timeout};
	}
	return {str => $str, timeout => $timeout, closed => $closed};
}



sub kill {
	my $self = shift;
	kill 'KILL', $self->{pid};
}



sub wait {
	my $self = shift;
	my $timeout = shift;

	eval {
		local $SIG{ALRM} = sub {die("alarm\n")};
		alarm 1;
		my $err = waitpid($self->{pid}, 0);
		die("waitpid($self->{pid}): $!") if ($err == -1);
		alarm 0;
	};

	# Has the eval die'd?
	if ($@) {
		# propagate non-alarm die
		die($@) if ($@ ne "alarm\n");

		# Kill that mother fucker!
		CORE::kill('KILL', $self->{pid}) or die("kill: $!");
		my $err = waitpid($self->{pid}, 0);
		die("waitpid($self->{pid}): $!") if ($err == -1);
		print "Process $self->{pid} didn't stop by itself. Killed!\n";
		return 0;
	} else {
		# Everything went better than expected!
		return 1;
	}
}




package ClientTester;

use warnings;
use strict;
use threads;
use Term::ANSIColor;


sub new {
	my $class = shift;
	my @args = @_;
	my $self = {};

	$self->{pr} = new PtyRunner();
	$self->{pr}->run(@args);

	bless $self, $class;
	return $self;
}



# Transform non-printable chars to their \x counterpart
sub _encode {
	my $str = shift;
	$str =~ s/\\/\\\\/;
	$str =~ s/\0/\\0/;
	$str =~ s/\t/\\t/;
	$str =~ s/\r/\\r/;
	$str =~ s/\n/\\n/;
	$str =~ s/([^\x20-\x7f])/sprintf("\\x%xd",ord $1)/eg;
	return $str;
}



sub start_slurp_stdout {
	my $self = shift;

	# Set the signal handler just for launching the thread
	my $oldhandler = $SIG{KILL};
	$SIG{KILL} = sub {threads->exit()};

	$self->{slurper} = async {
		while (1) {
			my $res = $self->{pr}->recv_stdout();
			print "[STDOUT] "._encode($res->{str})."\n" if (defined $res->{str});

			last if ($res->{closed});
		}
	};

	$SIG{KILL} = $oldhandler;
}



# Stop the slurper thread if any
sub stop_slurp_stdout {
	my $self = shift;
	my $kill = shift;

	return if (!defined $self->{slurper});

	$self->{slurper}->kill('KILL') if ($kill);
	$self->{slurper}->join();
	$self->{slurper} = undef;
}



sub end {
	my $self = shift;
	my $ret = $self->{pr}->wait();
	$self->stop_slurp_stdout(0);
	return $ret;
}



sub print_success {
	my $self = shift;
	# don't color \n nor empty lines
	my $text = shift;
	my @text = split "\n", $text, -1;
	print join "\n", map {$_ && colored($_, 'bold green')} @text;
}



sub print_fail {
	my $self = shift;
	# don't color \n nor empty lines
	my $text = shift;
	my @text = split "\n", $text, -1;
	print join "\n", map {$_ && colored($_, 'bold red')} @text;
}



sub send_line {
	my $self = shift;
	$self->{pr}->send(@_);
}



# Check whether the next line on the terminal identified by $out (either 'out'
# or 'err') starts with $str
# return a hash {
# 	ok => $ok,
# 	str => $line,
# 	timeout => $timeout,
# 	closed => $closed,
# 	errmsg => $errmsg
# }
# $errmsg contains an error message
# $line contains the line that has been read (if any)
sub expect_line_now {
	my $self = shift;
	my $out = shift;
	my $str = shift;
	my $errmsg = "";
	my $res;

	if ($out eq 'out') {
		$res = $self->{pr}->recv_line_stdout();
	} else {
		$res = $self->{pr}->recv_line_stderr();
	}

	# If we found a \n we know the connection isn't closed and we didn't timeouted

	if (substr($res->{str}, -1) ne "\n") {
		if ($res->{str} ne "") {
			$errmsg = "We found `"._encode($res->{str})."'";
			$errmsg .= " without a ending \\n while we expected ";
			$errmsg .= "`"._encode($str)."'\n";
		} else {
			$errmsg = "The expected `"._encode($str)."'";
			$errmsg .= " didn't come\n";
		}

		$res->{ok} = 0;
		$res->{errmsg} = $errmsg;
		return $res;
	}

	my $ok = int($res->{str} =~ /^\Q$str\E/i);
	if (!$ok) {
		$errmsg = "We found `"._encode($res->{str})."'";
		$errmsg .= " while we expected `"._encode($str)."'\n";
	} else {
		$errmsg = "success";
	}

	$res->{ok} = $ok;
	$res->{errmsg} = $errmsg;

	return $res;
}



# Check if the immediate next line starts with $str
# Plus it outputs errors or success messages.
# return 0 or 1 upon fail or success
sub checked_expect_line_now {
	my $self = shift;
	my $out = shift;
	my $str = shift;
	my $res = $self->expect_line_now($out, $str);

	if ($res->{ok}) {
		$self->print_success("[OK] "._encode($res->{str})."\n");
	} else {
		$self->print_fail($res->{errmsg});
		$self->print_fail("There was nothing to read\n") if ($res->{timeout});
		$self->print_fail("Connection was closed unexpectedly\n") if ($res->{closed});
	}

	return $res->{ok};
}



sub checked_expect_err_line_now {
	my $self = shift;
	return $self->checked_expect_line_now('err', @_);
}



# Wait for a line on $cnx starting with $str swallowing every intermediate lines
# return ($ok, $timeouted, $closed, $errmsg, @eatenlines)
# return a hash {
# 	ok => $ok,
# 	str => $line,
# 	timeout => $timeout,
# 	closed => $closed,
# 	errmsg => $errmsg,
# 	ignored => [@ign]
# }
# $errmsg contains an error message
# $line contains the line that has been read (if any)
# @ign contains the ignored lines before the matched one
sub expect_line {
	my $self = shift;
	my @ign;
	my $res;

	# Iterate through lines as long as there are some.
	do {
		$res = $self->expect_line_now(@_);
		push @ign, $res->{str} if ($res->{str});
	} while (!$res->{ok} && !$res->{timeout} && !$res->{closed});

	$res->{ignored} = \@ign;
	return $res;
}



# Look for the next line starting with $str swallowing every intermediate line
# Plus it outputs errors or success messages.
# return 0 or 1 upon fail or success
sub checked_expect_line {
	my $self = shift;
	my $out = shift;
	my $str = shift;
	my $res = $self->expect_line($out, $str);

	if ($res->{ok}) {
		$self->print_success("[OK] "._encode($res->{ignored}->[-1])."\n");
	} else {
		$self->print_fail($res->{errmsg});
		if ($res->{timeout}) {
			$self->print_fail("`$str' never came\n");
			$self->print_fail("Here are the ignored lines:\n");
			map {$self->print_fail("-> "._encode($_)."\n")} @{$res->{ignored}};
		}
		$self->print_fail("Connection was closed unexpectedly\n") if ($res->{closed});
	}

	return $res->{ok};
}


sub checked_expect_out_line {
	my $self = shift;
	return $self->checked_expect_line('out', @_);
}



package main;


use warnings;
use strict;
use Time::HiRes qw(sleep);


# Tests à rajouter
# Serveur local
# 	Envoie des premières lignes découpé (avec petite pause)
# 	Envoie de plusieurs lignes à la fois
# 	cd répertoire super large -> erreur
# 	téléchargement nom fichier super large -> erreur
# 	Téléchargement sur une addresse ip différente
# 	Authentification
# 	Port différent
# 	debug ?


sub slurp_file {
	my $filename = shift;

	open(my $f, '<', $filename) or return undef;
	my $string = do { local $/; <$f> };
	close($f);
	return $string;
}



sub test1 {
	print "\n\n[TEST1] Connexion, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test2 {
	print "\n\n[TEST2] Connexion, cd1, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("repertoire pub\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}


sub test3 {
	print "\n\n[TEST3] Connexion, cd2, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("repertoire pub/vpn\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test4 {
	print "\n\n[TEST4] Connexion, cd0, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("repertoire inexistent\n"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed to"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test5 {
	print "\n\n[TEST5] Connexion, ls, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("lister\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Here comes"));
	return 0 if (!$client->checked_expect_out_line("drwx------    2 0        0            4096 Sep 22  2005 lost+found"));
	return 0 if (!$client->checked_expect_out_line("drwx------    3 1010     0            4096 Sep 01  2005 priv"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x   10 105      0            4096 May 10  2010 pub"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory send"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test6 {
	print "\n\n[TEST6] Connexion, ls1, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("lister pub\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Here comes"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 Oct 20  2008 Test"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 May 10  2010 Tina"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 May 02  2005 jres2001"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 Feb 12  2008 linux"));
	return 0 if (!$client->checked_expect_out_line("lrwxrwxrwx    1 105      0               6 May 02  2005 netinfo -> reseau"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 0        0            4096 Jul 05  2006 pda"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    3 105      0            4096 May 02  2005 reseau"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    6 105      0            4096 Oct 16  2007 vpn"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    4 105      0            4096 Sep 14  2011 web-vpn"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory send"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test7 {
	print "\n\n[TEST7] Connexion, cd, ls1, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("repertoire pub\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	return 0 if (!$client->send_line("lister vpn\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Here comes"));
	return 0 if (!$client->checked_expect_out_line("-rw-r--r--    1 1007     1000          302 Jan 17  2007 conseils.txt"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 Nov 18  2008 linux"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 Jan 23  2008 macos"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 0        0            4096 Jan 17  2007 solaris"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    3 105      0            4096 Dec 16  2010 windows"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory send"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test8 {
	print "\n\n[TEST8] Connexion, cd2, téléchargement, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("repertoire pub/vpn\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	unlink "conseils.txt";
	return 0 if (!$client->send_line("recuperer conseils.txt\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



sub test9 {
	print "\n\n[TEST9] Connexion, téléchargement2, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	unlink "conseils.txt";
	return 0 if (!$client->send_line("recuperer pub/vpn/conseils.txt\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



sub test10 {
	print "\n\n[TEST10] Connexion, téléchargement3, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	unlink "inexistant.txt";
	return 0 if (!$client->send_line("recuperer /fichier/inexistant.txt\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	if (stat("inexistant.txt")) {
		$client->print_fail("An inexistent file has been created\n");
		return 1;
	} else {
		$client->print_success("[OK] The inexistent file hasn't been created\n");
	}

	return 1;
}



sub test11 {
	print "\n\n[TEST11] Connexion, cd0, téléchargement, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("repertoire inexistent\n"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed to"));
	unlink "conseils.txt";
	return 0 if (!$client->send_line("recuperer /pub/vpn/conseils.txt\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



sub test12 {
	print "\n\n[TEST12] Connexion, cd0, cd2, téléchargement0, téléchargement, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("repertoire inexistent\n"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed to"));
	return 0 if (!$client->send_line("repertoire pub/vpn\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	unlink "inexistant.txt";
	return 0 if (!$client->send_line("recuperer /fichier/inexistant.txt\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed"));
	unlink "conseils.txt";
	return 0 if (!$client->send_line("recuperer /pub/vpn/conseils.txt\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	if (stat("inexistant.txt")) {
		$client->print_fail("An inexistent file has been created\n");
		return 1;
	} else {
		$client->print_success("[OK] The inexistent file hasn't been created\n");
	}

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



sub test13 {
	print "\n\n[TEST13] fichier: connexion, déconnexion\n";

	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test14 {
	print "\n\n[TEST14] fichier: Connexion, cd1, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "repertoire pub\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}


sub test15 {
	print "\n\n[TEST15] fichier: Connexion, cd2, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "repertoire pub/vpn\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test16 {
	print "\n\n[TEST16] fichier: Connexion, cd0, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "repertoire inexistent\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed to"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test17 {
	print "\n\n[TEST17] fichier: Connexion, ls, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "lister\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Here comes"));
	return 0 if (!$client->checked_expect_out_line("drwx------    2 0        0            4096 Sep 22  2005 lost+found"));
	return 0 if (!$client->checked_expect_out_line("drwx------    3 1010     0            4096 Sep 01  2005 priv"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x   10 105      0            4096 May 10  2010 pub"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory send"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test18 {
	print "\n\n[TEST18] fichier: Connexion, ls1, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "lister pub\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Here comes"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 Oct 20  2008 Test"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 May 10  2010 Tina"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 May 02  2005 jres2001"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 Feb 12  2008 linux"));
	return 0 if (!$client->checked_expect_out_line("lrwxrwxrwx    1 105      0               6 May 02  2005 netinfo -> reseau"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 0        0            4096 Jul 05  2006 pda"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    3 105      0            4096 May 02  2005 reseau"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    6 105      0            4096 Oct 16  2007 vpn"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    4 105      0            4096 Sep 14  2011 web-vpn"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory send"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test19 {
	print "\n\n[TEST19] fichier: Connexion, cd, ls1, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "repertoire pub\n";
	print $ftpcmds "lister vpn\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Here comes"));
	return 0 if (!$client->checked_expect_out_line("-rw-r--r--    1 1007     1000          302 Jan 17  2007 conseils.txt"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 Nov 18  2008 linux"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 105      0            4096 Jan 23  2008 macos"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    2 0        0            4096 Jan 17  2007 solaris"));
	return 0 if (!$client->checked_expect_out_line("drwxr-xr-x    3 105      0            4096 Dec 16  2010 windows"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory send"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());
	return 1;
}



sub test20 {
	print "\n\n[TEST20] fichier: Connexion, cd2, téléchargement, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "repertoire pub/vpn\n";
	print $ftpcmds "recuperer conseils.txt\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	unlink "conseils.txt";

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



sub test21 {
	print "\n\n[TEST21] fichier: Connexion, téléchargement2, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "recuperer pub/vpn/conseils.txt\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	unlink "conseils.txt";

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



sub test22 {
	print "\n\n[TEST22] fichier: Connexion, téléchargement3, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "recuperer /fichier/inexistant.txt\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	unlink "inexistant.txt";

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	if (stat("inexistant.txt")) {
		$client->print_fail("An inexistent file has been created\n");
		return 1;
	} else {
		$client->print_success("[OK] The inexistent file hasn't been created\n");
	}

	return 1;
}



sub test23 {
	print "\n\n[TEST23] fichier: Connexion, cd0, téléchargement, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "repertoire inexistent\n";
	print $ftpcmds "recuperer /pub/vpn/conseils.txt\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	unlink "conseils.txt";

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed to"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



sub test24 {
	print "\n\n[TEST24] fichier: Connexion, cd0, cd2, téléchargement0, téléchargement, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "repertoire inexistent\n";
	print $ftpcmds "repertoire pub/vpn\n";
	print $ftpcmds "recuperer /fichier/inexistant.txt\n";
	print $ftpcmds "recuperer /pub/vpn/conseils.txt\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	unlink "inexistant.txt";
	unlink "conseils.txt";

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed to"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	if (stat("inexistant.txt")) {
		$client->print_fail("An inexistent file has been created\n");
		return 1;
	} else {
		$client->print_success("[OK] The inexistent file hasn't been created\n");
	}

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



sub test25 {
	print "\n\n[TEST25] Connexion, cd+cd, téléchargement, déconnexion\n";
	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->send_line("repertoire pub\nrepertoire vpn\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Directory successfully"));
	unlink "conseils.txt";
	return 0 if (!$client->send_line("recuperer conseils.txt\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->send_line("deconnecte\n"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



sub test26 {
	print "\n\n[TEST26] fichier: Connexion, cd long, déconnexion\n";
	open (my $ftpcmds, ">", "commands.ftp") or die("open(commands.ftp): $!");
	print $ftpcmds "repertoire ".("A"x(4*1024 - 6))."\n";
	print $ftpcmds "recuperer /pub/vpn/conseils.txt\n";
	print $ftpcmds "deconnecte\n";
	close($ftpcmds) or die("close(commands.ftp): $!");

	unlink "conseils.txt";

	my $client = new ClientTester($ARGV[0], '-h', 'ftp.univ-lyon1.fr', '-f', 'commands.ftp');
	$client->start_slurp_stdout();
	return 0 if (!$client->checked_expect_err_line_now("OK: Bienvenue"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Please specify"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Login successful"));
	return 0 if (!$client->checked_expect_err_line_now("ERR: Failed to"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Entering Passive"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Opening"));
	return 0 if (!$client->checked_expect_err_line_now("OK: File send"));
	return 0 if (!$client->checked_expect_err_line_now("OK: Goodbye"));
	return 0 if (!$client->end());

	my $expectedcontent = "Avant de r\xe9cup\xe9rer un client vpn, consultez la table de correspondance VPN_Client_Support_Matrix dans ce meme repertoire.\n\nEnsuite dans le r\xe9pertoire de votre OS, utilisez la version poss\xe9dant le num\xe9ro le plus \xe9lev\xe9, compatible avec votre syst\xe8me.\n\nL'installation doit ensuite se faire sans probl\xe8me.\n";

	my $actualcontent = slurp_file("conseils.txt");
	unlink "conseils.txt";

	if (!defined $actualcontent) {
		$client->print_fail("File conseils.txt hasn't been downloaded\n");
		return 0;
	} else {
		$client->print_success("[OK] The file has been downloaded\n");
	}

	if ($actualcontent ne $expectedcontent) {
		$client->print_fail("File conseils.txt doesn't contains what is expected\n");
		return 0;
	} else {
		$client->print_success("[OK] File content is right\n");
	}

	return 1;
}



my @testlist = (
	\&test1,
	\&test2,
	\&test3,
	\&test4,
	\&test5,
	\&test6,
	\&test7,
	\&test8,
	\&test9,
	\&test10,
	\&test11,
	\&test12,
	\&test13,
	\&test14,
	\&test15,
	\&test16,
	\&test17,
	\&test18,
	\&test19,
	\&test20,
	\&test21,
	\&test22,
	\&test23,
	\&test24,
	\&test25,
	\&test26
);



sub main {
	die "usage: $0 ftpclient\n" if (@ARGV != 1);

	my $numsuccess = 0;
	my $numfail = 0;

	foreach my $t (@testlist) {
		my $res = $t->();
		if ($res) {
			ClientTester->print_success("[TEST] OK\n");
			$numsuccess++;
			sleep 0.5;
		} else {
			ClientTester->print_fail("[TEST] FAILED\n");
			$numfail++;
			print "5 seconds before next test\n";
			sleep 5;
		}
	}

	print "$numsuccess tests réussis, $numfail échoués\n";
}


main();
