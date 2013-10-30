package App::riap::Commands;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

our %SPEC;

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
        paths => {
            summary => 'Path(s) (URIs) to list',
            schema => ['array*' => 'of' => 'str*'],
            req => 0,
            pos => 0,
            greedy => 1,
        },
    },
    "x.app.riap.aliases" => ["list"],
};
sub ls {
    my %args = @_;
    my $shell = $args{-shell};

    [200, "OK", "List completed"];

    #my $urip = @_ ? $_[0] : $shell->{_state}{pwd};
    #$shell->{_cmdstate}{res} = $shell->riap_request(
    #    list => $urip,
    #    {detail => $shell->{_cmdstate}{opts}{l}},
    #);
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
        path => {
            summary => '',
            schema  => ['str*'],
            req     => 1,
            pos     => 0,
        },
    },
};
sub cd {
    require File::Spec::Unix;

    my %args = @_;
    my $shell = $args{-shell};

    my $dir = @_ ? $_[0] : $shell->{_state}{start_pwd};
    my $opwd = $shell->{_state}{pwd};
    my $npwd;
    if ($dir eq '-') {
        if (defined $shell->{_state}{opwd}) {
            $npwd = $shell->{_state}{opwd};
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
        my $res = $shell->riap_request(info => $npwd);
    }
    $log->tracef("Setting npwd=%s, opwd=%s", $npwd, $opwd);
    $shell->{_state}{pwd}  = $npwd;
    $shell->{_state}{opwd} = $opwd;
    [200, "OK"];
}

$SPEC{set} = {
    v => 1.1,
    summary => "lists or sets setting",
    args => {
        name => {
            summary => '',
            schema  => ['str*'],
            pos     => 0,
        },
        value => {
            summary => '',
            schema  => ['any'],
            pos     => 1,
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
            summary => '',
            schema  => ['str*'],
            req     => 1,
            pos     => 0,
        },
    },
};
sub unset {
    my %args = @_;
    my $shell = $args{-shell};

    my $name = $args{name};

    return [400, "Unknown setting, use 'set' to list all known settings"]
        unless exists $shell->known_settings->{$name};
    delete $shell->{_setting}{$name};
    [200, "OK"];
}

1;

# ABSTRACT: riap shell commands
