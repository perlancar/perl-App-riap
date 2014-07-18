package App::riap;

use 5.010001;
use strict;
use utf8;
use warnings;
#use experimental 'smartmatch';
use Log::Any '$log';

use parent qw(Term::Shell);

use Color::ANSI::Util qw(ansifg);
use Data::Clean::JSON;
use Path::Naive qw(concat_path_n);
use Perinci::Sub::Util qw(err);
use Term::Detect::Software qw(detect_terminal_cached);
use Time::HiRes qw(time);

# VERSION
# DATE

my $cleanser = Data::Clean::JSON->get_cleanser;

sub new {
    require CHI;
    require Getopt::Long;
    require Perinci::Access;
    require URI;

    my ($class, %args) = @_;

    binmode(STDOUT, ":utf8");

    my %opts;
    my @gospec = (
        "help" => sub {
            print <<'EOT';
Usage:
  riap --help
  riap --version, -v
  riap [opts] [server-uri]

Options:
  --help            Show this help message
  --version, -v     Show version and exit
  --user=S, -u      Supply HTTP authentication user
  --password=S, -p  Supply HTTP authentication password

Examples:
  % riap
  % riap https://cpanlists.org/api/

For more help, see the manpage.
EOT
                exit 0;
        },
        "version|v"    => sub {
            say "riap version " . ($App::riap::VERSION // "dev");
            exit 0;
        },
        "user|u=s"     => \$opts{user},
        "password|p=s" => \$opts{password},
    );
    my $old_go_opts = Getopt::Long::Configure();
    Getopt::Long::GetOptions(@gospec);
    Getopt::Long::Configure($old_go_opts);

    $class->_install_cmds;
    my $self = $class->SUPER::new();
    $self->load_history;

    # load from file
    $self->load_settings;

    # override some settings from env, if available
    # ...

    $self->{_in_completion} = 0;

    # for now we don't impose cache size limit
    $self->{_cache} = CHI->new(driver=>'Memory', global=>1);

    # determine color support
    $self->{use_color} //= $ENV{COLOR} //
        detect_terminal_cached()->{color};

    # override some settings from cmdline args, if defined
    $self->{_pa} //= Perinci::Access->new;
    $self->setting(user     => $opts{user})     if defined $opts{user};
    $self->setting(password => $opts{password}) if defined $opts{password};

    # determine starting pwd
    my $pwd;
    my $surl = URI->new($ARGV[0] // "/");
    $self->state(server_url => $surl);
    my $res = $self->{_pa}->parse_url($surl);
    die "Can't parse url $surl\n" unless $res;
    $pwd = $res->{path};
    $self->state(pwd        => $pwd);
    $self->state(start_pwd  => $pwd);
    $self->run_cd($pwd);

    $self;
}

# override, readline workarounds
sub cmdloop {
    require Carp;
    require IO::Stty;
    require Signal::Safety;

    my $o = shift;
    my $rl = $o->{term};

    local $SIG{INT} = sub {
        # save history when we are interrupted
        $o->save_history;
        print STDERR "Interrupted\n";
        if ($rl->ReadLine eq 'Term::ReadLine::Gnu') {
            IO::Stty::stty(\*STDIN, 'echo');
        }
        exit 1;
    };

    local $SIG{__DIE__} = sub {
        IO::Stty::stty(\*STDIN, 'echo');
        $o->setting('debug_stack_trace') ? Carp::confess(@_) : die(@_);
    };

    local $SIG{__WARN__} = sub {
        IO::Stty::stty(\*STDIN, 'echo');
        $o->setting('debug_stack_trace') ? Carp::cluck(@_) : warn(@_);
    };

    # some workaround for Term::ReadLine
    # say "D0, rl=", $rl->ReadLine;
    my $attribs = $rl->Attribs;
    if ($rl->ReadLine eq 'Term::ReadLine::Gnu') {
        # TR::Gnu traps our INT handler
        # ref: http://www.perlmonks.org/?node_id=1003497
        $attribs->{catch_signals} = 0;
    } elsif ($rl->ReadLine eq 'Term::ReadLine::Perl') {
        # TR::Perl messes up colors
        # doesn't do anything?
        #$rl->ornaments(0);
        #$attribs->{term_set} = ["", "", "", ""];
    }

    $o->{stop} = 0;
    $o->preloop;
    while (1) {
        my $line;
        {
            no warnings 'once';
            local $Signal::Safety = 0; # limit the use of unsafe signals
            $line = $o->readline($o->prompt_str);
        }
        last unless defined($line);
        my $time1 = time();
        $o->cmd($line);
        my $time2 = time();
        if ($o->setting('debug_time_command')) {
            say sprintf("  %.3fs", ($time2-$time1));
        }
        last if $o->{stop};
    }
    $o->postloop;
}

sub mainloop { goto \&cmdloop }

sub colorize {
    my ($self, $text, $color) = @_;
    if ($self->{use_color}) {
        ansifg($color) . $text . "\e[0m";
    } else {
        $text;
    }
}

sub _json_obj {
    state $json;
    if (!$json) {
        require JSON;
        $json = JSON->new->allow_nonref;
    }
    $json;
}

sub json_decode {
    my ($self, $arg) = @_;
    $self->_json_obj->decode($arg);
}

sub json_encode {
    my ($self, $arg) = @_;
    my $data = $cleanser->clone_and_clean($arg);
    #use Data::Dump; dd $data;
    $self->_json_obj->encode($data);
}

sub settings_filename {
    my $self = shift;
    $ENV{RIAPRC} // "$ENV{HOME}/.riaprc";
}

sub history_filename {
    my $self = shift;
    $ENV{RIAP_HISTFILE} // "$ENV{HOME}/.riap_history";
}

sub known_settings {
    state $settings;
    if (!$settings) {
        require Perinci::Result::Format;
        $settings = {
            debug_riap => {
                summary => 'Whether to display raw Riap requests/responses',
                schema  => ['bool', default=>0],
            },
            debug_time_command => {
                summary => 'Show how long it takes to complete a command',
                schema  => ['bool', default=>0],
            },
            debug_completion => {
                summary => 'Whether to display debugging for tab completion',
                schema  => ['bool', default=>0],
            },
            debug_stack_trace => {
                summary => 'Whether to print stack trace on die/warning',
                schema  => ['bool', default=>0],
            },
            output_format => {
                summary => 'Output format for command (e.g. yaml, json, text)',
                schema  => ['str*', {
                    in=>[sort keys %Perinci::Result::Format::Formats],
                    default=>'text',
                }],
            },
            cache_period => {
                summary => 'Number of seconds to cache Riap results '.
                    'from server, to speed up things like tab completion',
                schema => ['int*', default=>300],
            },
            password => {
                summary => 'For HTTP authentication to server',
                schema  => 'str*',
            },
            user => {
                summary => 'For HTTP authentication to server',
                schema  => 'str*',
            },
        };
        require Data::Sah;
        for (keys %$settings) {
            for ($settings->{$_}{schema}) {
                $_ = Data::Sah::normalize_schema($_);
            }
        }
    }
    $settings;
}

sub setting {
    my $self = shift;
    my $name = shift;
    die "BUG: Unknown setting '$name'" unless $self->known_settings->{$name};
    if (@_) {
        my $oldval = $self->{_settings}{$name};
        $self->{_settings}{$name} = shift;
        return $oldval;
    }
    # return default value if not set
    unless (exists $self->{_settings}{$name}) {
        return $self->known_settings->{$name}{schema}[1]{default};
    }
    return $self->{_settings}{$name};
}

sub state {
    my $self = shift;
    my $name = shift;
    #die "BUG: Unknown state '$name'" unless $self->known_state_vars->{$name};
    if (@_) {
        my $oldval = $self->{_state}{$name};
        $self->{_state}{$name} = shift;
        return $oldval;
    }
    # return default value if not set
    #unless (exists $self->{_state}{$name}) {
    #    return $self->known_state_vars->{$name}{schema}[1]{default};
    #}
    return $self->{_state}{$name};
}

sub load_settings {
    my $self = shift;

    my $filename = $self->settings_filename;

  LOAD_FILE:
    {
        last unless $filename;
        last unless (-e $filename);
        $log->tracef("Loading settings from %s ...", $filename);
        open(my $fh, '<', $filename)
            or die "Can't open settings file $filename: $!\n";
        my $lineno = 0;
        while (<$fh>) {
            $lineno++;
            next unless /\S/;
            next if /^#/;
            my ($n, $v) = /(.+?)\s*=\s*(.+)/
                or die "$filename:$lineno: Invalid syntax in settings file\n";
            eval { $v = $self->json_decode($v) };
            $@ and die "$filename:$lineno: Invalid JSON in setting value: $@\n";
            $self->setting($n, $v);
        }
        close $fh;
    }
}

sub save_settings {
    die "Unimplemented";
}

sub clear_history {
    my $self = shift;

    if ($self->{term}->Features->{setHistory}) {
        $self->{term}->SetHistory();
    }
}

sub load_history {
    my $self = shift;

    if ($self->{term}->Features->{setHistory}) {
        my $filename = $self->history_filename;
        return unless $filename;
        if (-r $filename) {
            $log->tracef("Loading history from %s ...", $filename);
            open(my $fh, '<', $filename)
                or die "Can't open history file $filename: $!\n";
            chomp(my @history = <$fh>);
            $self->{term}->SetHistory(@history);
            close $fh or die "Can't close history file $filename: $!\n";
        }
    }
}

sub save_history {
    my $self = shift;

    if ($self->{term}->Features->{getHistory}) {
        my $filename = $self->history_filename;
        unless ($filename) {
            $log->warnf("Skipped saving history since filename not defined");
            return;
        }
        $log->tracef("Saving history to %s ...", $filename);
        open(my $fh, '>', $filename)
            or die "Can't open history file $filename for writing: $!\n";
        print $fh "$_\n" for grep { length } $self->{term}->GetHistory;
        close $fh or die "Can't close history file $filename: $!\n";
    }
}

sub postloop {
    my $self = shift;
    print "\n";
    $self->save_history;
}

sub prompt_str {
    my $self = shift;
    join(
        "",
        $self->colorize("riap", "4169e1"), " ", # royal blue
        $self->colorize($self->state("pwd"), "2e8b57"), " ", # seagreen
        "> ",
    );
}

sub riap_request {
    my ($self, $action, $uri, $extra0) = @_;
    my $copts = {
        user     => $self->setting('user'),
        password => $self->setting('password'),
    };

    my $surl = $self->state('server_url');

    my $extra = { %{ $extra0 // {} } };
    $extra->{uri} = $uri;

    my $show = $self->{_in_completion} ?
        $self->setting("debug_riap") && $self->setting("debug_completion") :
            $self->setting("debug_riap");

    if ($show) {
        say "DEBUG: Riap request: $action => $surl ".
            $self->json_encode($extra);
    }
    my $res;
    my $cache_key = $self->json_encode({action=>$action, %$extra});
    # we only want to cache some actions
    if ($action =~ /\A(info|list|meta)\z/ &&
            ($res = $self->{_cache}->get($cache_key))) {
        # cache hit
        if ($show) {
            say "DEBUG: Riap response (from cache): $action => $surl ".
                $res;
        }
        $res = $self->json_decode($res);
    } else {
        # cache miss, get from server
        $res  = $self->{_pa}->request($action, $surl, $extra, $copts);
        if ($show) {
            say "DEBUG: Riap response: ".$self->json_encode($res);
        }
        if ($self->setting('cache_period')) {
            $self->{_cache}->set($cache_key, $self->json_encode($res),
                                 $self->setting('cache_period')." s");
        }
    }
    $res;
}

sub _help_cmd {
    require Perinci::CmdLine;

    my ($self, %args) = @_;
    my $cmd = $args{name};

    local $ENV{VERBOSE} = 1;
    my $pericmd = Perinci::CmdLine->new(
        url => undef,
        log_any_app => 0,
        program_name => $args{name},
    );
    # hacks to avoid specifying url
    $pericmd->{_help_meta} = $args{meta};
    $pericmd->{_help_info} = {type=>'function'};
    for (qw/action format format_options version/) {
        delete $pericmd->common_opts->{$_};
    }
    $pericmd->common_opts->{json} = {
        getopt  => 'json',
        summary => 'Format result as JSON', # XXX translate
        handler => sub {},
    };
    $pericmd->run_help;
}

sub _run_cmd {
    require Perinci::Sub::GetArgs::Argv;
    require Perinci::Result::Format;
    local $Perinci::Result::Format::Enable_Cleansing = 1;

    my ($self, %args) = @_;
    my $cmd = $args{name};

    my $opt_help;
    my $opt_verbose;
    my $opt_fmt;

    my $res;
  RUN:
    {
        $res = Perinci::Sub::GetArgs::Argv::get_args_from_argv(
            argv => $args{argv},
            meta => $args{meta},
            check_required_args => 0,
            per_arg_json => 1,
            common_opts => {
                'help|h|?'  => sub { $opt_help = 1 },
                'verbose'   => sub { $opt_verbose = 1 },
                'json'      => sub { $opt_fmt = 'json-pretty' },
            },
        );
        if ($res->[0] == 502) {
            # try sending argv to the server because we can't seem to parse it
            $res = $args{code_argv}->(@{ $args{argv} });
            last RUN;
        }
        last RUN if $res->[0] != 200;

        if ($opt_help) {
            $self->_help_cmd(name=>$cmd, meta=>$args{meta});
            $res = [200, "OK"];
            last;
        }

        if ($res->[3] && defined $res->[3]{'func.missing_arg'}) {
            $res = [400, "Missing required arg '".
                        $res->[3]{'func.missing_arg'}."'"];
            last;
        }

        $res = $args{code}->(%{$res->[2]}, -shell => $self);
    }

    my $fmt = $opt_fmt //
        $res->[3]{"x.app.riap.default_format"} //
            $self->setting('output_format');

    print Perinci::Result::Format::format($res, $fmt);
}

sub comp_ {
    require Complete::Bash;
    require Complete::Util;

    my $self = shift;
    my ($cmd, $word0, $line, $start) = @_;

    local $self->{_in_completion} = 1;

    my @res = ("help", "exit");
    push @res, keys %App::riap::Commands::SPEC;

    # add functions
    my ($dir, $word) = $word0 =~ m!(.*/)?(.*)!;
    $dir //= "";
    my $pwd = $self->state("pwd");
    my $uri = length($dir) ? concat_path_n($pwd, $dir) : $pwd;
    $uri .= "/" unless $uri =~ m!/\z!;
    my $extra = {detail=>1};
    my $res = $self->riap_request(list => $uri, $extra);
    if ($res->[0] == 200) {
        for (@{ $res->[2] }) {
            my $u = $_->{uri};
            next unless $_->{type} =~ /\A(package|function)\z/;
            $u =~ s!\A\Q$uri\E!!;
            push @res, "$dir$u";
        }
    }
    #use Data::Dump; dd \@res;

    my $comp = Complete::Bash::mimic_dir_completion(
        Complete::Util::complete_array_elem(
            array=>\@res, word=>$word0),
    );
    if ($self->setting("debug_completion")) {
        say "DEBUG: Completion: ".join(", ", @$comp);
    }
    @$comp;
}

sub _err {
    require Perinci::Result::Format;

    my $self = shift;

    print Perinci::Result::Format::format($_[0], "text");
}

sub catch_run {
    my $self = shift;
    my ($cmd, @argv) = @_;

    my $pwd = $self->state("pwd");
    my $uri = concat_path_n($pwd, $cmd);
    my $res = $self->riap_request(info => $uri);
    if ($res->[0] == 404) {
        $self->_err([404, "No such command or executable (Riap function)"]);
        return;
    } elsif ($res->[0] != 200) {
        $self->_err($res);
        return;
    }
    unless ($res->[2]{type} eq 'function') {
        $self->_err([412, "Not an executable (Riap function)"]);
        return;
    }
    my $name = $res->[2]{uri}; $name =~ s!.+/!!;

    $res = $self->riap_request(meta => $uri);
    if ($res->[0] != 200) {
        $self->_err(err(500, "Can't get meta", $res));
        return;
    }
    my $meta = $res->[2];

    $self->_run_cmd(
        name=>$name, meta=>$meta, argv=>\@argv,
        code=>sub {
            my %args = @_;
            delete $args{-shell};
            $self->riap_request(call => $uri, {args=>\%args});
        },
        code_argv=>sub {
            $self->riap_request(call => $uri, {argv=>\@_});
        },
    );
}

sub catch_comp {
    require Perinci::Sub::Complete;
    require Complete::Util;

    my $self = shift;
    my ($cmd, $word, $line, $start) = @_;

    local $self->{_in_completion} = 1;

    my $pwd = $self->state("pwd");
    my $uri = concat_path_n($pwd, $cmd);
    my $res = $self->riap_request(info => $uri);
    return () unless $res->[0] == 200;
    return () unless $res->[2]{type} eq 'function';

    $res = $self->riap_request(meta => $uri);
    return () unless $res->[0] == 200;
    my $meta = $res->[2];

    local $ENV{COMP_LINE} = $line;
    local $ENV{COMP_POINT} = $start + length($word);
    $res = Perinci::Sub::Complete::complete_cli_arg(
        meta => $meta,
        riap_server_url => $self->state('server_url'),
        riap_uri        => $uri,
        riap_client     => $self->{_pa},
        common_opts     => {'help|h|?'=>sub{}, 'verbose|v'=>sub{},'json'=>sub{}},
        extra_completer_args => {-shell => $self},
    );

    @{ Complete::Bash::mimic_dir_completion(
        Complete::Util::complete_array_elem(
            array=>$res->{completion}, word=>$word)
      )};
}

my $installed = 0;
sub _install_cmds {
    my $class = shift;

    return if $installed;

    require App::riap::Commands;
    require Complete::Util;
    require Perinci::Sub::Wrapper;
    no strict 'refs';
    for my $cmd (sort keys %App::riap::Commands::SPEC) {
        $log->trace("Installing command $cmd ...");
        my $meta = $App::riap::Commands::SPEC{$cmd};
        my $code = \&{"App::riap::Commands::$cmd"};

        # we actually only want to normalize the meta
        my $res = Perinci::Sub::Wrapper::wrap_sub(
            sub     => \$code,
            meta    => $meta,
            compile => 0,
        );
        die "BUG: Can't wrap $cmd: $res->[0] - $res->[1]"
            unless $res->[0] == 200;
        $meta = $res->[2]{meta};

        #use Data::Dump; dd $meta;

        *{"smry_$cmd"} = sub { $meta->{summary} };
        *{"run_$cmd"} = sub {
            my $self = shift;
            $self->_run_cmd(name=>$cmd, meta=>$meta, argv=>\@_, code=>$code);
        };
        *{"comp_$cmd"} = sub {
            require Perinci::Sub::Complete;

            my $self = shift;
            my ($word, $line, $start) = @_;
            local $self->{_in_completion} = 1;
            local $ENV{COMP_LINE} = $line;
            local $ENV{COMP_POINT} = $start + length($word);
            my $res = Perinci::Sub::Complete::complete_cli_arg(
                meta => $meta,
                common_opts => {'help|h|?'=>sub{}, 'verbose|v'=>sub{},'json'=>sub{}},
                extra_completer_args => {-shell => $self},
            );
            my $comp = Complete::Bash::mimic_dir_completion(
                Complete::Util::complete_array_elem(
                    array=>$res->{completion}, word=>$word)
              );
            if ($self->setting('debug_completion')) {
                say "DEBUG: Completion: ".join(", ", @$comp);
            }
            @$comp;
        };
        if (@{ $meta->{"x.app.riap.aliases"} // []}) {
            # XXX not yet installed by Term::Shell?
            *{"alias_$cmd"} = sub { @{ $meta->{"x.app.riap.aliases"} } };
        }
        *{"help_$cmd"} = sub { $class->_help_cmd(name=>$cmd, meta=>$meta) };
    }
    $installed++;
}

1;
# ABSTRACT: Riap command-line client shell

=for Pod::Coverage ^(.+)$

=head1 SYNOPSIS

Use the provided L<riap> script.


=head1 DESCRIPTION

This is the backend/implementation of the C<riap> script.


=head1 SEE ALSO

L<Perinci::Access>

=cut
