package App::riap;

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';
use experimental 'smartmatch';

use base qw(Term::Shell);
use utf8;

our %cmdspec;

sub history_filename {
    my $self = shift;
    $ENV{RIAP_HISTFILE} // "$ENV{HOME}/.riap_history";
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
        return unless $filename;
        $log->tracef("Saving history to %s ...", $filename);
        open(my $fh, '>', $filename)
            or die "Can't open history file $filename for writing: $!\n";
        print $fh "$_\n" for grep { length } $self->{term}->GetHistory;
        close $fh or die "Can't close history file $filename: $!\n";
    }
}

sub settings {
    [qw/output_format user password/];
}

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

    $self->{_pa} //= Perinci::Access->new;
    $self->{_state}{user}          //= $opts{user};
    $self->{_state}{password}      //= $opts{password};

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

    $self->{_state}{output_format} //= $args{output_format} // "text";
    $self;
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
        user     => $self->{_state}{user},
        password => $self->{_state}{password},
    };
    $self->{_pa}->request($action, $uri, $extra, $copts);
}

sub _run_cmd {
    require Getopt::Long;
    require Perinci::Result::Format;

    my ($self, %args) = @_;

    $self->{_cmdstate} = {};

    my @argv = @{ $args{argv} };
    # convert opts to Getopt::Long specification
    {
        my @gospec;
        for my $ok (keys %{ $args{opts} // {} }) {
            my $ov = $args{opts}{$ok};

            my $ospec;
            if (length($ok) > 1) {
                $ospec = "--$ok";
            } else {
                $ospec = "-$ok";
            }
            if ($ov->{aliases}) {
                $ospec .= "|$_" for @{ $ov->{aliases} };
            }
            if ($ov->{arg_type}) {
                if ($ov->{arg_type} eq 'bool') {
                    $ospec .= "!";
                } else {
                    $ospec .= "=s";
                }
            }
            push @gospec, $ospec;
            push @gospec, sub {
                $self->{_cmdstate}{opts}{$ok} = $_[1];
            };
        }
        $log->tracef("Getopt::Long spec: %s", \@gospec);
        $self->{_cmdstate}{opts} = {};
        my $old_go_opts = Getopt::Long::Configure();
        my $res = Getopt::Long::GetOptionsFromArray(\@argv, @gospec);
        Getopt::Long::Configure($old_go_opts);
    }

    # call code
    $args{run}->($self, @argv);

    # display result
    if ($self->{_cmdstate}{res}) {
        print Perinci::Result::Format::format(
            $self->{_cmdstate}{res},
            $self->{_state}{output_format});
    }
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

$cmdspec{list} = {
    summary => "Perform list request on package entity",
    aliases => ['ls'],
    opts => {
        l => {
        },
    },
    run => sub {
        my $self = shift;
        my $urip = @_ ? $_[0] : $self->{_state}{pwd};
        $self->{_cmdstate}{res} = $self->riap_request(
            list => $urip,
            {detail => $self->{_cmdstate}{opts}{l}},
        );
    },
};

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
                map { {name=>$_, value=>$self->{_state}{$_}} }
                    @{ $self->settings }
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
    no strict 'refs';
    for my $cmd (keys %cmdspec) {
        my $spec = $cmdspec{$cmd};
        *{"smry_$cmd"} = sub { $spec->{summary} };
        *{"run_$cmd"} = sub {
            my $self = shift;
            $self->_run_cmd(%{ $spec }, argv=>\@_);
        };
        *{"comp_$cmd"} = sub {
            my $self = shift;
            $self->_comp_cmd(%{ $spec }, argv=>\@_);
        };
        if (@{ $spec->{aliases} // []}) {
            *{"alias_$cmd"} = sub { @{ $spec->{aliases} } };
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
