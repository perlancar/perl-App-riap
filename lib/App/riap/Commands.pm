package App::riap::Commands;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Path::Naive qw(is_abs_path normalize_path concat_path_n);
#use Perinci::Sub::Util qw(err);

# VERSION

our %SPEC;

my $_complete_dir_or_file = sub {
    my $which = shift;

    my %args = @_;
    my $shell = $args{parent_args}{parent_args}{extra_completer_args}{-shell};

    my $word0 = $args{word};
    my ($dir, $word) = $word0 =~ m!(.*/)?(.*)!;
    $dir //= "";

    my $pwd = $shell->state("pwd");
    my $uri = length($dir) ? concat_path_n($pwd, $dir) : $pwd;
    $uri .= "/" unless $uri =~ m!/\z!;
    my $extra = {};
    $extra->{type} = 'package' if $which eq 'dir';
    $extra->{type} = 'function' if $which eq 'executable';
    my $res = $shell->riap_request(list => $uri, $extra);
    return [] unless $res->[0] == 200;
    my @res = ();
    push @res, "../" unless $uri eq '/';
    for (@{ $res->[2] }) {
        s/\A\Q$uri\E//;
        push @res, "$dir$_";
    }

    # trick to mimic shell's behavior (taken from periscomp code): if a single
    # dir foo/ matches, don't let completion complete and add spaces, so user
    # can Tab several times to drill down path, which is convenient.
    if (@res == 1 && $res[0] =~ m!/\z!) {
        push @res, "$res[0] ";
    }

    \@res;
};

my $complete_dir = sub {
    $_complete_dir_or_file->('dir', @_);
};

my $complete_file_or_dir = sub {
    $_complete_dir_or_file->('file_or_dir', @_);
};

my $complete_executable = sub {
    $_complete_dir_or_file->('executable', @_);
};

my $complete_setting_name = sub {
    my %args = @_;
    my $shell = $args{parent_args}{parent_args}{extra_completer_args}{-shell};

    [keys %{ $shell->known_settings }];
};

# format of summary: <shell-ish description> (<equivalent in terms of Riap>)
#
# for format of description, we follow Term::Shell style: no first-letter cap,
# verb in 3rd person present tense.

$SPEC{ls} = {
    v => 1.1,
    summary => 'lists contents of packages (Riap list request)',
    args => {
        long => {
            summary => 'Long mode (detail=1)',
            schema => ['bool'],
            cmdline_aliases => {
                l => {},
            },
        },
        # XXX temporarily use single path instead of multipl, periscomp can't
        # handle it

        #paths => {
        #    summary    => 'Path(s) (URIs) to list',
        #    schema     => ['array*' => 'of' => 'str*'],
        #    req        => 0,
        #    pos        => 0,
        #    greedy     => 1,
        #    completion => $complete_file_or_dir,
        #},
        path => {
            summary    => 'Path (URI) to list',
            schema     => 'str*',
            req        => 0,
            pos        => 0,
            completion => $complete_file_or_dir,
        },
    },
    "x.app.riap.aliases" => ["list"],
};
sub ls {
    my %args = @_;
    my $shell = $args{-shell};

    my $extra = {}; $extra->{detail} = 1 if $args{long};
    my $pwd = $shell->state("pwd");
    my $path = $args{path};
    my $uri;
    my ($dir, $leaf);

    $uri = $pwd . ($pwd =~ m!/\z! ? "" : "/");
    if (defined $path) {
        ($dir, $leaf) = $path =~ m!(.*/)?(.*)!;
        $dir //= "";
        if (length $dir) {
            $uri = concat_path_n($pwd, $dir);
            $uri .= ($uri =~ m!/\z! ? "" : "/");
        }
    }
    my $res = $shell->riap_request(list => $uri, $extra);

    my @res;
    for (@{ $res->[2] }) {
        my $u = $args{long} ? $_->{uri} : $_;
        next if defined($leaf) && length($leaf) && $u !~ m!.+/\Q$leaf\E/?\z!;
        push @res, $_;
    }
    if (!@res && defined($leaf)) {
        return [404, "No such entity"];
    }
    $res->[2] = \@res;
    [200, "OK", \@res];
}

$SPEC{pwd} = {
    v => 1.1,
    summary => 'shows current directory',
    args => {
    },
};
sub pwd {
    my %args = @_;
    my $shell = $args{-shell};

    [200, "OK", $shell->{_state}{pwd}];
}

$SPEC{cd} = {
    v => 1.1,
    summary => "changes directory",
    args => {
        dir => {
            summary    => '',
            schema     => ['str*'],
            pos        => 0,
            completion => $complete_dir,
        },
    },
};
sub cd {
    my %args = @_;
    my $dir = $args{dir};
    my $shell = $args{-shell};

    my $opwd = $shell->state("pwd");
    my $npwd;
    if (!defined($dir)) {
        # back to start pwd
        $npwd = $shell->state("start_pwd");
    } elsif ($dir eq '-') {
        if (defined $shell->state("old_pwd")) {
            $npwd = $shell->state("old_pwd");
        } else {
            warn "No old pwd set\n";
            return [200, "Nothing done"];
        }
    } else {
        if (is_abs_path($dir)) {
            $npwd = normalize_path($dir);
        } else {
            $npwd = concat_path_n($opwd, $dir);
        }
    }
    # check if path actually exists
    my $uri = $npwd . ($npwd =~ m!/\z! ? "" : "/");
    my $res = $shell->riap_request(info => $uri);
    return $res if $res->[0] != 200;
    #return [403, "Not a directory (package)"]
    #    unless $res->[2]{type} eq 'package';

    $log->tracef("Setting npwd=%s, opwd=%s", $npwd, $opwd);
    $shell->state(pwd     => $npwd);
    $shell->state(old_pwd => $opwd);
    [200, "OK"];
}

$SPEC{set} = {
    v => 1.1,
    summary => "lists or sets setting",
    args => {
        name => {
            summary    => '',
            schema     => ['str*'],
            pos        => 0,
            # we use custom completion because the list of known settings must
            # be retrieved through the shell object
            completion => $complete_setting_name,
        },
        value => {
            summary    => '',
            schema     => ['any'],
            pos        => 1,
            completion => sub {
                require Perinci::Sub::Complete;

                my %args = @_;
                my $shell = $args{parent_args}{parent_args}->
                    {extra_completer_args}{-shell};

                my $args = $args{args};
                return [] unless $args->{name};
                my $setting = $shell->known_settings->{ $args->{name} };
                return [] unless $setting;

                # a hack, construct a throwaway meta and using that to complete
                # setting argument as function argument
                Perinci::Sub::Complete::complete_arg_val(
                    arg=>'foo',
                    meta=>{v=>1.1, args=>{foo=>{schema=>$setting->{schema}}}},
                );
            },
        },
    },
};
sub set {
    my %args = @_;
    my $shell = $args{-shell};

    my $name  = $args{name};

    if (exists $args{value}) {
        # set setting
        return [400, "Unknown setting, use 'set' to list all known settings"]
            unless exists $shell->known_settings->{$name};
        $shell->setting($name, $args{value});
        [200, "OK"];
    } else {
        # list settings
        my $res = [];
        if (defined $name) {
            return [400,"Unknown setting, use 'set' to list all known settings"]
                unless exists $shell->known_settings->{$name};
        }
        for (keys %{ $shell->known_settings }) {
            next if defined($name) && $_ ne $name;
            push @$res, {
                name => $_,
                summary => $shell->known_settings->{$_}{summary},
                value   => $shell->{_settings}{$_},
                default => $shell->known_settings->{$_}{schema}[1]{default},
            };
        }
        my $rfo = {table_column_orders=>[[qw/name summary value default/]]};
        [200, "OK", $res, {result_format_options=>{
            text          => $rfo,
            "text-pretty" => $rfo,
        }}];
    }
}

$SPEC{unset} = {
    v => 1.1,
    summary => "unsets a setting",
    args => {
        name => {
            summary    => '',
            schema     => ['str*'],
            req        => 1,
            pos        => 0,
            completion => $complete_setting_name,
        },
    },
};
sub unset {
    my %args = @_;
    my $shell = $args{-shell};

    my $name = $args{name};

    return [400, "Unknown setting, use 'set' to list all known settings"]
        unless exists $shell->known_settings->{$name};
    delete $shell->{_settings}{$name};
    [200, "OK"];
}

1;

# ABSTRACT: riap shell commands

=for Pod::Coverage .+
