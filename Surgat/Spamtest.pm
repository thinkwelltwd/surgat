package Surgat::Spamtest;

use strict;
use IO::File;
use Mail::SpamAssassin::Logger qw(:DEFAULT log_message);
use Mail::SpamAssassin::Util qw(untaint_var exit_status_str
                                am_running_on_windows);
use Surgat::Log qw(do_log);

# These may need adjusting...
my $PREFIX = '/usr';
my $DEF_RULES_DIR = '/usr/share/spamassassin';
my $LOCAL_RULES_DIR = '/etc/spamassassin';
my $LOCAL_STATE_DIR = '/var/lib/spamassassin';

# Return values from process()
use constant RESULT_HAM       => 0;
use constant RESULT_SPAM      => 1;
use constant RESULT_TOO_LARGE => 2;

sub new {
    my ($this, $config) = @_;
    my $class = ref($this) || $this;
    my $self = {setuid_to_user => 0, default_user => 'nobody', msg_count => 0 };
    bless($self, $class);

    $self->{max_msg_count} = $config->{'max-conn-per-child'};
    $self->{log_level} = $config->{'log-level'};
    $self->get_home($config);
    $self->{log_level} = $config->{'log-level'};

    # enable debug as early as possible to help with debugging problems!
    if ($config->{'debug'} ne '') {
        my $dbg = $config->{'debug'} ||= 'info';
        do_log(2, "Enabling debug for spamassassin: ".$config->{'debug'});
        Mail::SpamAssassin::Logger::add_facilities($dbg);
    }

    my %cfg_opts = $config->section("Spamassassin");
    foreach my $key (keys %cfg_opts) {
        $self->{$key} = $cfg_opts{$key};
    };

    $self->{current_user} = $self->{default_user};

    my %sa_cfg;
    $self->spamassassin_config($config, \%sa_cfg);
    $self->{sa_obj} = Mail::SpamAssassin->new(\%sa_cfg);


    # from spamd

    # should be done post-daemonize such that any files created by this
    # process are written with the right ownership and everything.
    $self->preload_modules_with_tmp_homedir();

    # this must be after preload_modules_with_tmp_homedir(), for bug 5606
    $self->{sa_obj}->init_learner({
        opportunistic_expire_check_only => 1,
    });
    # bayes DBs may still be tied() at this point, so untie them and such.
    $self->{sa_obj}->finish_learner();

#    $self->{sa_obj}->init(0);
#    $self->{sa_obj}->compile_now(0);

    $self->{sa_version} = Mail::SpamAssassin::Version();
    $self->{sa_version} =~ s/([0-9]*\.[0-9]*).*/$1/;

    return $self;
}

sub lint {
    my $self = shift;
    return $self->{sa_obj}->lint_rules();
}

sub get_home {
    my ($self, $config) = shift;
    if (defined $ENV{'HOME'}) {
        if ($config->{'username'}) {
            if (my $nh = ( getpwname($config->{'username'}))[7]) {
                $self->{orighome} = $nh;
            } else {
                die "Unable to determine home directory for user '".
                    $config->{'username'}."'\n";
            }
        }
    }
}

sub spamassassin_config {
    my ($self, $config, $hashref) = @_;
    $hashref->{require_rules} = 1;
    $hashref->{rules_filename} = $self->{'configpath'};
    $hashref->{site_rules_filename} = $self->{'siteconfigpath'};
    $hashref->{post_config_text} = $config->{'cf'} if scalar(@{$config->{'cf'}});
    $hashref->{local_tests_only} = $self->{'local-only'};
    $hashref->{paranoid} = $self->{'paranoid'};
# Setting this causes issues with recent versions of spamassassin
#    $hashref->{force_ipv4} = $config->{'ipv4-only'};
    $hashref->{dont_copy_prefs} = ! $self->{'create-prefs'};
    $hashref->{username} = $config->{'username'};
    $hashref->{home_dir_for_helpers} = $self->{'helper-home-dir'};
}

# Taken from spamd
sub preload_modules_with_tmp_homedir {
    my $self = shift;
    # set $ENV{HOME} in /tmp while we compile and preload everything.
    # File::Spec->tmpdir uses TMPDIR, TMP, TEMP, C:/temp, /tmp etc.
    my $tmpdir = File::Spec->tmpdir();
    if ( !$tmpdir ) {
        die "cannot find writable tmp dir, set TMP or TMPDIR in environment";
    }

    # If TMPDIR isn't set, File::Spec->tmpdir() will set it to undefined.
    # that then breaks other things ...
    delete $ENV{'TMPDIR'} if ( !defined $ENV{'TMPDIR'} );

    my $tmphome = File::Spec->catdir( $tmpdir, "spamd-$$-init" );
    $tmphome = Mail::SpamAssassin::Util::untaint_file_path($tmphome);

    my $tmpsadir = File::Spec->catdir( $tmphome, ".spamassassin" );

    do_log(4, "Preloading modules with HOME=$tmphome");

    # bug 5379: spamd won't start if the temp preloading dir exists;
    # be sure to remove it just in case 
    if (-d $tmpsadir) {
        rmdir( $tmpsadir ) or die "$tmpsadir not empty: $!";
    }
    if (-d $tmphome) {
        rmdir( $tmphome ) or die "$tmphome not empty: $!";
    }
    mkdir( $tmphome,  0700 ) or die "spamd: cannot create $tmphome: $!";
    mkdir( $tmpsadir, 0700 ) or die "spamd: cannot create $tmpsadir: $!";
    $ENV{HOME} = $tmphome;

    $self->{sa_obj}->compile_now(0,1);  # ensure all modules etc. are loaded
    $/ = "\n";                          # argh, Razor resets this!  Bad Razor!

    # now clean up the stuff we just created, and make us taint-safe
    delete $ENV{HOME};

    # bug 2015, bug 2223: rmpath() is not taint safe, so we've got to implement
    # our own poor man's rmpath. If it fails, we report only the first error.
    my $err;
    foreach my $d ( ( $tmpsadir, $tmphome ) ) {
        opendir( TMPDIR, $d ) or $err ||= "open $d: $!";
        unless ($err) {
            foreach my $f ( File::Spec->no_upwards( readdir(TMPDIR) ) ) {
                $f = Mail::SpamAssassin::Util::untaint_file_path(
                    File::Spec->catfile( $d, $f ) );
                unlink($f) or $err ||= "remove $f: $!";
            }
            closedir(TMPDIR) or $err ||= "close $d: $!";
        }
        rmdir($d) or $err ||= "remove $d: $!";
    }

    # If the dir still exists, log a warning.
    if ( -d $tmphome ) {
        $err ||= "do something: $!";
        do_log(1, "failed to remove $tmphome: could not $err\n");
    }
}

sub process {
    my ($self, $msg, $user) = @_;
    my $start_time = time;

    $self->{msg_count}++;
    do_log(3, "started processing message ".$self->{msg_count}.
              "/".$self->{max_msg_count}." @ $start_time");

    $msg->seek(0,0);
    my $size = ($msg->stat)[7] or die "Can't stat mail file: $!";
    
    # Only process message under --maxsize KB
    if ( $size > ($self->{'max-size'} * 1024) ) {
        do_log(1, "message is too large for spam processing (".
             "$size bytes vs maximum of ".($self->{maxsize} * 1024).
             " bytes).");
        return RESULT_TOO_LARGE;
    }

    my ($mail, $actual_length) = $self->parse_file($msg, $start_time);
    my ($msgid, $rmsgid) = $self->parse_msgids($mail);

    my @recd = $mail->get_pristine_header("Received");
    do_log(4, "got a total of ".(scalar @recd)." headers to parse for recipient...");
    # As the message has been delievered to us, the first Received header will
    # record that delivery and as such won't tell us who it was intended for!
    # Quick fix - skip the first header and use the second.
    if (scalar @recd >= 1 && $recd[0] =~ /for \<(.*)\>;/is) {
        $self->set_user($1);
    }

    do_log(2, "processing message $msgid".($rmsgid ? " aka $rmsgid" : "")
       . " for ".$self->{current_user}." : $>");
    if ($size != $actual_length) {
        do_log(1, "Content-Length mismatch: Expected $size bytes, got $actual_length bytes");
        $mail->finish();
        return 0;
    }

    my $status = Mail::SpamAssassin::PerMsgStatus->new($self->{sa_obj}, $mail);
    $status->check();

    my $msg_score = &Mail::SpamAssassin::Util::get_tag_value_for_score($status->get_score, 
              $status->get_required_score, $status->is_spam);
    my $msg_threshold = sprintf( "%2.1f", $status->get_required_score );

    my $result;
    my $was_it_spam;
    if ($status->is_spam) {
        $result = RESULT_SPAM;
        $was_it_spam = 'identified spam';
    } else {
        $result = RESULT_HAM;
        $was_it_spam = 'clean message';
    }

    $self->{response} = IO::File->new_tmpfile;
    $self->{response}->print($status->rewrite_mail());

    my $scantime = sprintf( "%.1f", time - $start_time );
    do_log(2, "$was_it_spam ($msg_score/$msg_threshold) for ".$self->{current_user}." in"
       . " $scantime seconds, $actual_length bytes." );

    # ??? Should we do this here or store the status & mail objects until the
    # message has been sent onwards before doing the training? Possible move
    # this to the finish() function?
    if ($status->{'bayes_expiry_due'}) {
        do_log(3, "bayes expiry was marked as due, running post-check");
        $self->{sa_obj}->rebuild_learner_caches();
        $self->{sa_obj}->finish_learner();
    }
    $status->finish();
    $mail->finish();
    return $result;
}

sub finish {
    my $self = shift;
    if (defined $self->{response}) {
        $self->{response}->close;
        undef $self->{response};
    }
}

sub parse_file {
    my ($self, $fh, $start_time) = @_;

    $fh->seek(0,0) or die "Can't rewind message file: $!";
    my $actual_length = 0;
    my @msglines = ();

    while (defined($_ = $fh->getline())) {
        $actual_length += length($_);   
        push(@msglines, $_);
    }

    my $mail = $self->{sa_obj}->parse(\@msglines, 0,
                       !$self->{timeout} || !$start_time ? ()
                       : { master_deadline => $start_time + $self->{timeout} });
    return ($mail, $actual_length);
}
  
sub parse_msgids {
    my ($self, $mail) = @_;

    # Extract the Message-Id(s) for logging purposes.
    my $msgid  = $mail->get_pristine_header("Message-Id");
    my $rmsgid = $mail->get_pristine_header("Resent-Message-Id");
    foreach my $id ((\$msgid, \$rmsgid)) {
        if ( $$id ) {
            while ( $$id =~ s/\([^\(\)]*\)// ) { } # remove comments and
            $$id =~ s/^\s+|\s+$//g;          # leading and trailing spaces
            $$id =~ s/\s+/ /g;               # collapse whitespaces
            $$id =~ s/^.*?<(.*?)>.*$/$1/;    # keep only the id itself
            $$id =~ s/[^\x21-\x7e]/?/g;      # replace all weird chars
            $$id =~ s/[<>]/?/g;              # plus all dangling angle brackets
            $$id =~ s/^(.+)$/<$1>/;          # re-bracket the id (if not empty)
        }
    }
    return ($msgid, $rmsgid);
}

sub set_user {
    my ($self, $user) = @_;

    if ($user !~ /^([\x20-\xFF]*)$/ ) {
        do_log(2, "Username contains control chars??? [$user]");
        return 0;
    }
    do_log(3, "setting user to '$user'");
    $self->{current_user} = $user;

    if ($self->{'nouser-config'}) {
        if ($self->{'sql-config'}) {
            do_log(4, "getting user prefs from SQL");
            unless ($self->handle_user_sql($self->{current_user}) ) {
                do_log(1, "Error fetching user preferences via SQL");
                return 0;
            }
            do_log(3, "SQL preferences being used for ".$self->{current_user});
        } elsif ($self->{virtual_config_dir}) {
            $self->handle_virtual_config_dir($self->{current_user});
        } elsif ($self->{'sql-setuid'} ) {
            unless ($self->handle_user_setuid_with_sql($self->{current_user})) {
                do_log(2, "Error fetching user preferences via SQL");
                return 0;
            }
            $self->{setuid_to_user} = 1;    #to benefit from any paranoia.
        } else {
            do_log(4, "handle_user_setuid_basic...");
            $self->handle_user_setuid_basic($self->{current_user});
        }
    } else {
        $self->handle_user_setuid_basic($self->{current_user});
        if ($self->{'sql-config'}) {
            unless ($self->handle_user_sql($self->{current_user})) {
                do_log(2, "Error fetching user preferences via SQL");#
            	return 0;
            }
        }
    }
    return 1;
}

sub handle_user_sql {
    my ($self, $username) = @_;
    do_log(4, "handle_user_sql($username)");
    unless ($self->{sa_obj}->load_scoreonly_sql($username)) {
        return 0;
    }
    $self->{sa_obj}->signal_user_changed({
        username => $username,
        user_dir => undef
    });
    return 1;
}

# Handle user configs without the necessity of having individual users or a
# SQL/LDAP database.
sub handle_virtual_config_dir {
    my ($self, $username) = @_;

    my $dir = $self->{virtual_config_dir};
    my $userdir;
    my $prefsfile;

    if ( defined $dir ) {
        my $safename = $username;
        $safename =~ s/[^-A-Za-z0-9\+_\.\,\@\=]/_/gs;
        my $localpart = '';
        my $domain    = '';
        if ( $safename =~ /^(.*)\@(.*)$/ ) { $localpart = $1; $domain = $2; }

        $dir =~ s/\%u/${safename}/g;
        $dir =~ s/\%l/${localpart}/g;
        $dir =~ s/\%d/${domain}/g;
        $dir =~ s/\%\%/\%/g;

        $userdir   = $dir;
        $prefsfile = $dir . '/user_prefs';

        # Log that the default configuration is being used for a user.
        do_log(2, "using default config for $username: $prefsfile");
    }

    if ( -f $prefsfile ) {
       # Found a config, load it.
       $self->{sa_obj}->read_scoreonly_config($prefsfile);
    }

    # assume that $userdir will be a writable directory we can
    # use for Bayes dbs etc.
    $self->{sa_obj}->signal_user_changed({
        username => $username,
        userstate_dir => $userdir,
        user_dir => $userdir
    });
    return 1;
}

sub handle_user_set_user_prefs {
    my ($self, $dir, $username) = @_;

    # don't do this if we weren't passed a directory
    if ($dir) {
        my $cf_file = $dir . "/.spamassassin/user_prefs";
        # Parse user scores, creating default .cf if needed:
        if (!-r $cf_file && !$self->{sa_obj}->{'dont_copy_prefs'}) {
            do_log(3, "creating default_prefs: $cf_file");
            # If vpopmail config enabled then pass virtual homedir onto
            # create_default_prefs via $userdir
            $self->{sa_obj}->create_default_prefs( $cf_file, $username, $dir );

            if (! -r $cf_file) {
                do_log(2, "failed to create readable default_prefs: $cf_file");
            }
        }
        $self->{sa_obj}->read_scoreonly_config($cf_file);
    }

    # signal_user_changed will ignore undef user_dirs, so this is ok
    $self->{sa_obj}->signal_user_changed({
        username => $username,
        user_dir => $dir
    });
    return 1;
}

sub handle_user_setuid_basic {
    my ($self, $username) = @_;

    # If $opt{'username'} in use, then look up userinfo for that uid;
    # otherwise use what was passed via $username
    #
    my $suidto = $username;
    if ($self->{username} ) {
        $suidto = $self->{username};
    }

    my ($name, $pwd, $uid, $gid, $quota, $comment, $gcos, $suiddir, $etc) =
      am_running_on_windows() ? ('nobody') : getpwnam($suidto);

    if (!defined $uid) {
        my $errmsg = "handle_user unable to find user: '$suidto'\n";
        die $errmsg if $self->{sa_obj}->{'paranoid'};
        # if we are given a username, but can't look it up, maybe name
        # services are down?  let's break out here to allow them to get
        # 'defaults' when we are not running paranoid
        do_log(2, $errmsg);
        return 0;
    }

    if ($self->{setuid_to_user}) {
        $) = "$gid $gid";                 # change eGID
        $> = $uid;                        # change eUID
        if ( !defined($uid) || ( $> != $uid and $> != ( $uid - 2**32 ) ) ) {
            # make it fatal to avoid security breaches
            die("fatal error: setuid to $suidto failed");
        } else {
            do_log(3, "setuid to $suidto succeeded");
        }
    }

    my $userdir;

    # if $opt{'user-config'} is in use, read user prefs from the remote
    # username's home dir (if it exists): bug 5611
    if (! $self->{'nouser-config'}) {
        my $prefsfrom = $username;  # the one passed, NOT $opt{username}
        if ($prefsfrom eq $suidto) {
            $userdir = $suiddir;  # reuse the already-looked-up info, tainted
        } else {
            $userdir = (getpwnam($prefsfrom))[7];
        }

        # we *still* die if this can't be found
        if (!defined $userdir) {
            my $errmsg = "handle_user unable to find user: '$prefsfrom'\n";
            die $errmsg if $self->{sa_obj}->{'paranoid'};
            # if we are given a username, but can't look it up, maybe name
            # services are down?  let's break out here to allow them to get
            # 'defaults' when we are not running paranoid
            do_log(1, $errmsg);
            return 0;
        }
    }

    # call this anyway, regardless of --user-config, so that
    # signal_user_changed() is called
    $self->handle_user_set_user_prefs(untaint_var($userdir), $username);
}

sub handle_user_setuid_with_sql {
    my ($self, $username) = @_;

    # Bug 6313: interestingly, if $username is not tainted than $pwd, $gcos and
    # $etc end up tainted but other fields not;  if $username _is_ tainted,
    # getpwnam does not complain, but all returned fields are tainted (which
    # makes sense, but is worth remembering)
    #
    my ($name, $pwd, $uid, $gid, $quota, $comment, $gcos, $dir, $etc) =
      getpwnam(untaint_var($username));

    if (!$self->{sa_obj}->{'paranoid'} && !defined($uid)) {
        # if we are given a username, but can't look it up, maybe name
        # services are down?  let's break out here to allow them to get
        # 'defaults' when we are not running paranoid
        do_log(2, "handle_user unable to find user: $username\n");
        return 0;
    }

    if ($self->{setuid_to_user}) {
        $) = "$gid $gid";                 # change eGID
        $> = $uid;                        # change eUID
        if (!defined($uid) || ($> != $uid and $> != ($uid - 2**32))) {
            # make it fatal to avoid security breaches
            die("fatal error: setuid to $username failed");
        }
        else {
            do_log(1, "setuid to $username succeeded, reading scores from SQL");
        }
    }

    my $spam_conf_dir = $dir . '/.spamassassin'; # needed for Bayes, etc.
    if ((! $self->{'nouser-config'} || defined $self->{'helper-home-dir'})) {
        if (mkdir $spam_conf_dir, 0700) {
            do_log(1, "created $spam_conf_dir for $username");
        } else {
            do_log(1, "failed to create $spam_conf_dir for $username");
        }
    }

    unless ($self->{sa_obj}->load_scoreonly_sql($username)) {
        return 0;
    }

    $self->{sa_obj}->signal_user_changed( { username => $username } );
    return 1;
}

1;
