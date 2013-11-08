package App::riap::ColorTheme::Default;

use 5.010;
use strict;
use warnings;

# VERSION

our %color_themes = (

    no_color => {
        v => 1.1,
        summary => 'Special theme that means no color',
        colors => {
        },
        no_color => 1,
    },

    default => {
        v => 1.1,
        summary => 'Default (for terminal with black background)',
        colors => {
            path      => '2e8b57', # seagreen
        },
    },

);

1;
# ABSTRACT: Default color themes
