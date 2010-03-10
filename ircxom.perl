#!/usr/bin/perl

use warnings;
use strict;

use lib ".";

use POE;
use Client::IRC;

POE::Kernel->run();
exit 0;
