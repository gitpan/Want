BEGIN { $| = 1; print "1..51\n"; }

# Test that we can load the module
END {print "not ok 1\n" unless $loaded;}
use Want;
$loaded = 1;
print "ok 1\n";

# Now test the private low-level mechanisms

sub lv :lvalue {
    print (Want::want_lvalue(0) ? "ok 2\n" : "not ok 2\n");
    my $xxx;
}

&lv = 23;

sub rv :lvalue {
    print (Want::want_lvalue(0) ? "not ok 3\n" : "ok 3\n");
    my $xxx;
}

&rv;

sub foo {
    my $t = shift();
    my $opname = Want::parent_op_name(0);
    print ($opname eq shift() ? "ok $t\n" : "not ok $t\t# $opname\n");
    ++$t;
    my $c = Want::want_count(0);
    print ($c == shift() ? "ok $t\n" : "not ok $t\t# $c\n");
    "";
}

($x, undef) = foo(4, "aassign", 2);
$x = 2 + foo(6, "add", 1);

foo(8, "(none)", 0);

print foo(10, "print", -1);

@x = foo (12, "aassign", -1);

# Test the public API

#  wantref()
sub wc {
    my $ref = Want::wantref();
    print ($ref eq 'CODE' ? "ok 14\n" : "not ok 14\t# $ref\n");
    sub {}
}
wc()->();

sub wh {
    my $n = shift();
    my $ref = Want::wantref();
    print ($ref eq 'HASH' ? "ok $n\n" : "not ok $n\t# $ref\n");
    {}
}
wh(15)->{foo};
%{wh(16)};
@{wh(17)}{qw/foo bar/};

sub wg {
    my $n = shift();
    my $ref = Want::wantref();
    print ($ref eq 'GLOB' ? "ok $n\n" : "not ok $n\t# $ref\n");
    \*foo;
}
*{wg(18)};
*{wg(19)}{FORM};

sub wa {
    my $n = shift();
    my $ref = Want::wantref();
    print ($ref eq 'ARRAY' ? "ok $n\n" : "not ok $n\t# $ref\n");
    [];
}
@{wa(20)};
${wa(21)}[23];
wa(22)->[24];

#  howmany()

sub hm {
  my $n = shift();
  my $x = shift();
  my $h = Want::howmany();
  
  print (!defined($x) && !defined($h) || $x eq $h ? "ok $n\n" : "not ok $n\t# $h\n");
}

hm(23, 0);
@x = hm(24, undef);
(undef) = hm(25, 1);

#  want()

use Want 'want';
sub pi () {
    if    (want('ARRAY')) {
	return [3, 1, 4, 1, 5, 9];
    }
    elsif (want('LIST')) {
	return (3, 1, 4, 1, 5, 9);
    }
    else {
	return 3;
    }
}
print (pi->[2]   == 4 ? "ok 26\n" : "not ok 26\n");
print (((pi)[3]) == 1 ? "ok 27\n" : "not ok 27\n");

sub tc {
    print (want(2) && !want(3) ? "ok 28\n" : "not ok 28\n");
}

(undef, undef) = tc();

sub g :lvalue {
    my $t = shift;
    print (want(@_) ? "ok $t\n" : "not ok $t\n");
    $y;
}
sub ng :lvalue {
    my $t = shift;
    print (want(@_) ? "not ok $t\n" : "ok $t\n");
    $y;
}

(undef) =  g(29, 'LIST', 1);
(undef) = ng(30, 'LIST', 2);

$x      =  g(31, '!LIST', 1);
$x      = ng(32, '!LIST', 2);

g(33, 'RVALUE', 'VOID');
g(34, 'LVALUE', 'SCALAR') = 23;
@x = g(35, 'RVALUE', 'LIST');
@x = \(g(36, 'LVALUE', 'LIST'));
($x) = \(scalar g(37, 'RVALUE'));
$$x = 29;
print ($y != 29 ? "ok 37\n" : "not ok 37\n");

g(38, 'HASH')->{foo};
ng(39, 'REF');
&{g(40, 'CODE')};
sub main::23 {}

(undef, undef,  undef) = ($x,  g(41, 2));
(undef, undef,  undef) = ($x, ng(42, 3));

($x) = ($x, ng(43, 1));

@x = g(44, 2);
%x = g(45, 'Infinity');
@x{@x} = g(46, 'Infinity');

@x[1, 2] = g(47, 2, '!3');
@x{@x{1, 2}} = g(48, 2, '!3');
@x{()} = g(49, 0, '!1');

@x = (@x, g(50, 'Infinity'));
($x) = (@x, g(51, '!1'));