package App::riap;

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';
use experimental 'smartmatch';

use parent qw(Term::Shell);
use utf8;

our %cmdspec;
our $json;

sub new {
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
  riap [opts] [URI]

Options:
  --help        Show this help message
  --user=S      Supply HTTP authentication user
  --password=S  Supply HTTP authentication password

Examples:
  % riap
  % riap https://cpanlists.org/api/

For more help, see the manpage.
EOT
                exit 0;
        },
        "user=s"     => \$opts{user},
        "password=s" => \$opts{password},
    );
    my $old_go_opts = Getopt::Long::Configure();
    Getopt::Long::GetOptions(@gospec);
    Getopt::Long::Configure($old_go_opts);

    my $self = $class->SUPER::new();
    $self->load_history;
    $self->load_settings;

    $self->{_pa} //= Perinci::Access->new;
    $self->{_settings}{user} = $opts{user}
        if defined $opts{user};
    $self->{_settings}{password} = $opts{password}
        if defined $opts{password};

    # determine starting pwd
    my $pwd;
    my $surl = URI->new($ARGV[0] // "pl:/");
    $surl->scheme('pl') if !$surl->scheme;
    $self->{_state}{server_url}    //= $surl;
    my $res = $self->{_pa}->parse_url($surl);
    die "Can't parse url $surl\n" unless $res;
    $pwd = $res->{path};
    $pwd = "/$pwd" unless $pwd =~ m!^/!;
    $pwd .= "/" unless $pwd =~ m!/$!;
    $self->{_state}{pwd}           //= $pwd;
    $self->{_state}{start_pwd}     //= $pwd;

    $self;
}

sub _json_obj {
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
    $self->_json_obj->encode($arg);
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
            debug_show_request => {
                summary => 'Whether to display raw Riap requests being sent',
                schema => ['bool', default=>0],
            },
            debug_show_response => {
                summary => 'Whether to display raw Riap responses from server',
                schema => ['bool', default=>0],
            },
            output_format => {
                schema => ['str*', {
                    in=>[sort keys %Perinci::Result::Format::Formats],
                    default=>'text',
                }],
            },
            password => {
                schema => 'str*',
            },
            user => {
                schema => 'str*',
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
        $self->{_settings}{$name} = shift;
    }
    $self->{_settings}{$name};
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

    # fill in defaults
    my $kss = $self->known_settings;
    for (keys %$kss) {
        if (!exists($self->{_settings}{$_})) {
            $self->{_settings}{$_} = $kss->{$_}{schema}[1]{default};
        }
    }
}

sub save_settings {
    die "Unimplemented";
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
    "riap> ";
}

sub riap_request {
    my ($self, $action, $uri, $extra) = @_;
    my $copts = {
        user     => $self->setting('user'),
        password => $self->setting('password'),
    };
    $self->{_pa}->request($action, $uri, $extra, $copts);
}

sub _run_cmd {
    require Perinci::Sub::GetArgs::Argv;
    require Perinci::Result::Format;

    my ($self, %args) = @_;

    my $opt_help;
    my $opt_verbose;

    my $res = Perinci::Sub::GetArgs::Argv::get_args_from_argv(
        argv => $args{argv},
        meta => $args{meta},
        check_required_args => 0,
        extra_getopts_before => [
            'help|h|?' => \$opt_help,
            'verbose' => \$opt_verbose,
        ],
    );
    return $res unless $res->[0] == 200;

    if ($opt_help) {
        local $ENV{VERBOSE} = 1;
            require Perinci::CmdLine;
        my $pericmd = Perinci::CmdLine->new(
            # currently no effect due to url undef
            #summary => $args{meta}{summary},
            url => undef,
            log_any_app => 0,
            program_name => $args{name},
        );
        for (qw/action format format_options version/) {
            delete $pericmd->common_opts->{$_};
        }
        $pericmd->run_help;
        return;
    }

        $res = $args{code}->(%{$res->[2]}, -shell => $self);

    print Perinci::Result::Format::format(
        $res, $self->setting('output_format'));
}

sub _comp_cmd {
    require Perinci::BashComplete;

    my ($self, %args) = @_;

    #use Data::Dump; dd $args{argv};
    my @argv = @{ $args{argv} };
    my ($word, $line, $start) = @argv;

    # currently rather simplistic, only complete option name or uri path
    #my @left = $self->line_parsed(substr($line, 0, $start));
    #my @right = ...
    if ($word =~ /^-/) {
        my @opts;
        for my $ok (keys %{ $args{opts} }) {
            my $ov = $args{opts}{$ok};
            push @opts, length($ok) > 1 ? "--$ok" : "-$ok";
            for (@{ $ov->{aliases} // [] }) {
                push @opts, length($_) > 1 ? "--$_" : "-$_";
            }
        }
        return @{ Perinci::BashComplete::complete_array(
            word=>$word, array=>\@opts) };
    } else {
        # complete path
    }

    ();
}

$cmdspec{pwd} = {
    summary => "Show current location",
    opts => {
    },
    run => sub {
        my $self = shift;
        say $self->{_state}{pwd};
    },
};

$cmdspec{cd} = {
    summary => "Change location",
    opts => {
    },
    run => sub {
        require File::Spec::Unix;

        my $self = shift;
        my $dir = @_ ? $_[0] : $self->{_state}{start_pwd};
        my $opwd = $self->{_state}{pwd};
        my $npwd;
        if ($dir eq '-') {
            if (defined $self->{_state}{opwd}) {
                $npwd = $self->{_state}{opwd};
            } else {
                warn "No old pwd set\n";
                return;
            }
        } else {
            if (File::Spec::Unix->file_name_is_absolute($dir)) {
                $npwd = $dir;
            } else {
                $npwd = File::Spec::Unix->catdir($opwd, $dir);
            }
            $npwd = File::Spec::Unix->canonpath($npwd);
            # canonpath() doesn't cleanup foo/..
            $npwd =~ s![^/]+/\.\.(?=/|\z)!!g;
            $npwd .= "/" unless $npwd =~ m!/$!;

            # check if path actually exists
            my $res = $self->riap_request(info => $npwd);
        }
        $log->tracef("Setting npwd=%s, opwd=%s", $npwd, $opwd);
        $self->{_state}{pwd}  = $npwd;
        $self->{_state}{opwd} = $opwd;
    },
};

$cmdspec{set} = {
    summary => "List or set settings",
    opts => {
    },
    run => sub {
        my $self = shift;
        if (!@_) {
            $self->{_cmdstate}{res} = [
                map { +{
                    name          => $_,
                    summary       => $self->known_settings->{$_}{summary},
                    value         => $self->{_settings}{$_},
                    default_value => $self->known_settings->{$_}{schema}[1]{default},
                } } sort keys %{ $self->{_settings} }
            ];
            return;
        }
        unless (@_ == 2) {
            warn "Usage: set <setting> <value>\n";
        }
        my $s = $_[0];
        unless ($s ~~ @{ $self->settings }) {
            warn "Unknown setting '$s', use 'set' to list known settings\n";
            return;
        }
        $self->{_state}{$s} = $_[1];
    },
};

$cmdspec{unset} = {
    summary => "Unset a setting",
    opts => {
    },
    run => sub {
        my $self = shift;
        unless (@_ == 1) {
            warn "Usage: unset <setting>\n";
            return;
        }
        my $s = $_[0];
        unless ($s ~~ @{ $self->settings }) {
            warn "Unknown setting '$s', use 'set' to list current settings\n";
            return;
        }
        delete $self->{_state}{$s};
    },
};

# install commands
{
    require App::riap::Commands;
    require Perinci::Sub::Wrapper;
    no strict 'refs';
    for my $cmd (keys %App::riap::Commands::SPEC) {
        my $meta = $App::riap::Commands::SPEC{$cmd};
        my $code = \&{"App::riap::Commands::$cmd"};

        # we actually only want to normalize the meta,
        my $res = Perinci::Sub::Wrapper::wrap_sub(
            sub     => \$code,
            meta    => $meta,
            #compile => 0, # periwrap 0.46- emits warnings
        );
        die "BUG: Can't wrap $cmd: $res->[0] - $res->[1]"
            unless $res->[0] == 200;
        $meta = $res->[2]{meta};

        *{"smry_$cmd"} = sub { $meta->{summary} };
        *{"run_$cmd"} = sub {
            my $self = shift;
            $self->_run_cmd(name=>$cmd, meta=>$meta, argv=>\@_, code=>$code);
        };
        *{"comp_$cmd"} = sub {
            my $self = shift;
        };
        if (@{ $meta->{"x.app.riap.aliases"} // []}) {
            *{"alias_$cmd"} = sub { @{ $meta->{"x.app.riap.aliases"} } };
        }
    }
}

1;
# ABSTRACT: Implementation for the riap command-line shell

=for Pod::Coverage ^(.+)$

=head1 SYNOPSIS

Use the provided L<riap> script.


=head1 DESCRIPTION

This is the backend/implementation of the C<riap> script.


=head1 SEE ALSO

L<Perinci::Access>

=cut
