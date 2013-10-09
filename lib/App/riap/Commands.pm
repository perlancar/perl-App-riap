package App::riap::Commands;

use 5.010;
use strict;
use warnings;

our %SPEC;

# format of summary: <shell-ish description> (<equivalent in terms of riap>)

$SPEC{ls} = {
    v => 1.1,
    summary => 'lists contents of packages (performs list request)',
    args => {
        long => {
            summary => 'Long mode (detail=1)',
            schema => ['bool'],
            cmdline_aliases => {
                l => {},
            },
        },
        paths => {
            summary => 'Path(s) to list',
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
    [200, "OK", "List completed"];

    #my $urip = @_ ? $_[0] : $self->{_state}{pwd};
    #$self->{_cmdstate}{res} = $self->riap_request(
    #    list => $urip,
    #    {detail => $self->{_cmdstate}{opts}{l}},
    #);
}

1;

# ABSTRACT: riap shell commands
