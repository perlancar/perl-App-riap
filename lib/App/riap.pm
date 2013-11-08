package App::riap;

use 5.010001;
use strict;
use utf8;
use warnings;
#use experimental 'smartmatch';
use Log::Any '$log';

use parent qw(Term::Shell);
use Moo;
with 'SHARYANTO::Role::ColorTheme';

use Data::Clean::JSON;
use Path::Naive qw(concat_path_n);
use Term::ANSIColor;

# VERSION

my $cleanser = Data::Clean::JSON->get_cleanser;

sub new {
    require Getopt::Long;
    require Perinci::Access;
    require URI;

    my ($class, $args) = @_;

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

    $class->_install_cmds;
    my $self = $class->SUPER::new();
    $self->load_history;
    $self->load_settings;

    # set some settings from cmdline args
    $self->{_pa} //= Perinci::Access->new;
    $self->setting(user     => $opts{user})     if defined $opts{user};
    $self->setting(password => $opts{password}) if defined $opts{password};

    # determine starting pwd
    my $pwd;
    my $surl = URI->new($ARGV[0] // "pl:/");
    $surl->scheme('pl') if !$surl->scheme;
    my $res = $self->{_pa}->parse_url($surl);
    die "Can't parse url $surl\n" unless $res;
    $self->state(server_url => $surl);
    $self->state(pwd        => $res->{path});
    $self->state(start_pwd  => $res->{path});

    # set color theme
    say "use_color=", $self->use_color;
    $self->color_theme("Default::default");

    $self;
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
    $self->_json_obj->encode($cleanser->clone_and_clean($arg));
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
                schema  => ['bool', default=>0],
            },
            debug_show_response => {
                summary => 'Whether to display raw Riap responses from server',
                schema  => ['bool', default=>0],
            },
            output_format => {
                summary => 'Output format for command (e.g. yaml, json, text)',
                schema  => ['str*', {
                    in=>[sort keys %Perinci::Result::Format::Formats],
                    default=>'text',
                }],
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
    my $prompt = join(
        "",
        $self->get_theme_color_as_ansi("path"), "riap", " ",
        $self->state("pwd"), " ",
        "> ",
    );
    use Data::Dump; dd $prompt;
    $prompt;
}

sub riap_request {
    my ($self, $action, $uri, $extra) = @_;
    my $copts = {
        user     => $self->setting('user'),
        password => $self->setting('password'),
    };
    if ($self->setting("debug_show_request")) {
        say "DEBUG: Riap request: ".
            $self->json_encode({action=>$action, uri=>$uri, %{$extra // {}}});
    }
    my $res = $self->{_pa}->request($action, $uri, $extra, $copts);
    if ($self->setting("debug_show_request")) {
        say "DEBUG: Riap response: ".$self->json_encode($res);
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
    $pericmd->run_help;
}

sub _run_cmd {
    require Perinci::Sub::GetArgs::Argv;
    require Perinci::Result::Format;

    my ($self, %args) = @_;
    my $cmd = $args{name};

    my $opt_help;
    my $opt_verbose;

    my $res;
    {
        $res = Perinci::Sub::GetArgs::Argv::get_args_from_argv(
            argv => $args{argv},
            meta => $args{meta},
            check_required_args => 0,
            per_arg_json => 1,
            extra_getopts_before => [
                'help|h|?'  => \$opt_help,
                'verbose|v' => \$opt_verbose,
            ],
        );
        last unless $res->[0] == 200;

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
    print Perinci::Result::Format::format(
        $res, $self->setting('output_format'));
}

sub comp_ {
    require SHARYANTO::Complete::Util;

    my $self = shift;
    my ($cmd, $word0, $line, $start) = @_;

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

    @{ SHARYANTO::Complete::Util::complete_array(array=>\@res, word=>$word0) };
}

sub catch_run {
    my $self = shift;
    my ($cmd, @argv) = @_;

    my $pwd = $self->state("pwd");
    my $uri = concat_path_n($pwd, $cmd);
    my $res = $self->riap_request(info => $uri);
    if ($res->[0] == 404) {
        return [404, "No such command or executable"];
    } elsif ($res->[0] != 200) {
        return $res;
    }
    do {
        say "ERROR: Not an executable (Riap function)";
        return;
    } unless $res->[2]{type} eq 'function';
    my $name = $res->[2]{uri}; $name =~ s!.+/!!;

    $res = $self->riap_request(meta => $uri);
    return $res unless $res->[0] == 200;
    my $meta = $res->[2];

    $self->_run_cmd(
        name=>$name, meta=>$meta, argv=>\@argv,
        code=>sub {
            my %args = @_;
            delete $args{-shell};
            $self->riap_request(call => $uri, {args=>\%args});
        },
    );
}

sub catch_comp {
    require Perinci::Sub::Complete;

    my $self = shift;
    my ($cmd, $word, $line, $start) = @_;

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
    $res = Perinci::Sub::Complete::shell_complete_arg(
        meta => $meta,
        common_opts => [qw/--help -h -? --verbose -v/],
        extra_completer_args => {-shell => $self},
    );
    @$res;
}

my $installed = 0;
sub _install_cmds {
    my $class = shift;

    return if $installed;

    require App::riap::Commands;
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
            local $ENV{COMP_LINE} = $line;
            local $ENV{COMP_POINT} = $start + length($word);
            my $res = Perinci::Sub::Complete::shell_complete_arg(
                meta => $meta,
                common_opts => [qw/--help -h -? --verbose -v/],
                extra_completer_args => {-shell => $self},
            );
            @$res;
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
# ABSTRACT: Implementation for the riap command-line shell

=for Pod::Coverage ^(.+)$

=head1 SYNOPSIS

Use the provided L<riap> script.


=head1 DESCRIPTION

This is the backend/implementation of the C<riap> script.


=head1 SEE ALSO

L<Perinci::Access>

=cut
