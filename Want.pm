package Want;

require v5.6;
use Carp 'croak';
use strict;
use warnings;

require Exporter;
require DynaLoader;

our @ISA = qw(Exporter DynaLoader);

our @EXPORT_OK = qw(want howmany wantref);
our $VERSION = '0.01';

bootstrap Want $VERSION;

my %reftype = (
    ARRAY => 1,
    HASH  => 1,
    CODE  => 1,
    GLOB  => 1,
);

sub want {
    my @args = @_;
    
    my $wantref = _wantref(2);
    for my $arg (@args) {
	if    ($arg =~ /^\d+$/) {
	    return 0 unless want_count(1) >= $arg;
	}
	elsif ($arg eq 'REF') {
	    return 0 unless $wantref;
	}
	elsif ($reftype{$arg}) {
	    return 0 unless defined($wantref) && $wantref eq $arg;
	}
	elsif ($arg eq 'LVALUE') {
	    return 0 unless want_lvalue(1);
	}
	elsif ($arg eq 'RVALUE') {
	    return 0 unless !want_lvalue(1);
	}
	elsif ($arg eq 'VOID') {
	    return 0 unless !defined(wantarray_up(1));
	}
	elsif ($arg eq 'SCALAR') {
	    return 0 unless defined(wantarray_up(1)) && 0 == wantarray_up(1);
	}
	elsif ($arg eq 'NONLIST') {
	    return 0 unless !wantarray_up(1);
	}
	elsif ($arg eq 'LIST') {
	    return 0 unless wantarray_up(1);
	}
	else {
	    croak ("want: Unrecognised specifier $arg");
	}
    }
    
    return 1;
}

sub howmany () {
    my $count = want_count(1);
    return ($count < 0 ? undef : $count);
}

sub wantref () { @_ = (1); goto &_wantref }

sub _wantref {
    my $n = parent_op_name(shift());
    if    ($n eq 'rv2av') {
	return "ARRAY";
    }
    elsif ($n eq 'rv2hv') {
	return "HASH";
    }
    elsif ($n eq 'rv2cv' || $n eq 'entersub') {
	return "CODE";
    }
    elsif ($n eq 'rv2gv' || $n eq 'gelem') {
	return "GLOB";
    }
    else {
	return "";
    }
}

1;

__END__

=head1 NAME

Want - Implement the C<want> command

=head1 SYNOPSIS

  use Want ('want');
  sub foo :lvalue {
      if    (want('lvalue')) {
        return $x;
      }
      elsif (want->{LIST}) {
        return (1, 2, 3);
  }

=head1 DESCRIPTION

This module generalises the mechanism of the B<wantarray> function,
allowing a function to determine in some detail how its return value
is going to be immediately used.

=head2 Top-level contexts:

The three kinds of top-level context are well known:

=over 4

=item B<VOID>

The return value is not being used in any way; the function call is an entire
statement:

  foo();

=item B<SCALAR>

The return value is being treated as a scalar value of some sort:

  my $x = foo();
  $y += foo();
  print "123" x foo();
  print scalar foo();
  warn foo()->{23};
  ...etc...

=item B<LIST>

The return value is treated as a list of values:

  my @x = foo();
  my ($x) = foo();
  () = foo();		# even though the results are discarded
  print foo();
  bar(foo());		# unless the bar subroutine has a prototype
  print @hash{foo()};	# (hash slice)
  ...etc...

=back

=head2 Lvalue subroutines:

The introduction of B<lvalue subroutines> in Perl 5.6 has created a new type
of contextual information, which is independent of those listed above. When
an lvalue subroutine is called, it can either be called in the ordinary way
(so that its result is treated as an ordinary value, an B<rvalue>); or else
it can be called so that its result is considered updatable, an B<lvalue>.

These rather arcane terms (lvalue and rvalue) are easier to remember if you
know why they are so called. If you consider a simple assignment statement
C<left = right>, then the B<l>eft-hand side is an B<l>value and the B<r>ight-hand
side is an B<r>value.

So (for lvalue subroutines only) there are two new types of context:

=over 4

=item B<RVALUE>

The caller is definitely not trying to assign to the result:

  foo();
  my $x = foo();
  ...etc...

=item B<LVALUE>

Either the caller is directly assigning to the result of the sub call:

  foo() = $x;
  foo() = (1, 1, 2, 3, 5, 8);

or the caller is making a reference to the result, which might be assigned to
later:

  my $ref = \(foo());	# Could now have: $$ref = 99;
  
  # Note that this example imposes LIST context on the sub call.
  # So we're taking a reference to the first element to be
  # returned _in list context_.
  # If we want to call the function in scalar context, we can
  # do it like this:
  my $ref = \(scalar foo());

or else the result of the function call is being used as part of the argument list
for I<another> function call:

  bar(foo());	# Will *always* call foo in lvalue context,
  		# regardless of what bar actually does.

The reason for this last case is that bar might be a sub which modifies its
arguments. They're rare in contemporary Perl code, but still possible:

  sub bar {
    $_[0] = 23;
  }

=back

=head2 Reference context:

Sometimes in list context the caller is expecting a reference of some sort
to be returned:

    print foo()->();     # CODE reference expected
    print foo()->{bar};  # HASH reference expected
    print foo()->[23];   # ARRAY reference expected
    
    my $format = *{foo()}{FORMAT} # GLOB reference expected

You can check this using conditionals like C<if (want('CODE'))>.
There is also a function C<wantref()> which returns one of the strings
"CODE", "HASH", "ARRAY" or "GLOB"; or the empty string if a reference
is not expected.

=head2 Item count

Sometimes in list context the caller is expecting a particular number of items
to be returned:

    my ($x, $y) = foo();   # foo is expected to return two items

If you pass a number to the C<want> function, then it will return true or false
according to whether at least that many items are wanted. So if we are in the
definition of a sub which is being called as above, then:

    want(1) returns true
    want(2) returns true
    want(3) returns false

The C<howmany> function can be used to find out how many items are wanted.
If the context is scalar, then C<want(1)> returns true and C<howmany()> returns
1. If you want to check whether your result is being assigned to a singleton
list, you can say C<if (want('LIST', 1)) { ... }>.

=head1 EXAMPLES

    use Carp 'croak';
    use Want 'howmany';
    sub numbers {
	my $count = howmany();
	croak("Can't make an infinite list") if !defined($count);
	return (1..$count);
    }
    my ($one, $two, $three) = numbers();
    
    
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
    print pi->[2];	# prints 4
    print ((pi)[3]);	# prints 1

=head1 EXPORT

None by default. The C<want>, C<wantref> and/or C<howmany> functions can be imported:

  use Want qw'want howmany';

If you don't import these functions, you must qualify their names as (e.g.)
C<Want::want>.

=head1 INTERFACE

This is the first release of this module, and the public interface may change in
future versions. It's too early to make any guarantees about interface stability.

I'd be interested to know how you're using this module.

=head1 AUTHOR

Robin Houston, E<lt>robin@kitsite.comE<gt>

=head1 SEE ALSO

=over 4

=item *

L<perlfunc/wantarray>

=item *

Perl6 RFC 21, by Damian Conway.
http://dev.perl.org/rfc/21.html

=back

=head1 COPYRIGHT

Copyright (c) 2001, Robin Houston. All Rights Reserved.
This module is free software. It may be used, redistributed
and/or modified under the same terms as Perl itself.

=cut
