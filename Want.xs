#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/* Stolen from B.xs */

#ifdef PERL_OBJECT
#undef PL_op_name
#undef PL_opargs 
#undef PL_op_desc
#define PL_op_name (get_op_names())
#define PL_opargs (get_opargs())
#define PL_op_desc (get_op_descs())
#endif


/* Stolen from pp_ctl.c (with modifications) */

I32
dopoptosub_at(pTHX_ PERL_CONTEXT *cxstk, I32 startingblock)
{
    dTHR;
    I32 i;
    PERL_CONTEXT *cx;
    for (i = startingblock; i >= 0; i--) {
        cx = &cxstk[i];
        switch (CxTYPE(cx)) {
        default:
            continue;
        //case CXt_EVAL:
        case CXt_SUB:
        case CXt_FORMAT:
            DEBUG_l( Perl_deb(aTHX_ "(Found sub #%ld)\n", (long)i));
            return i;
        }
    }
    return i;
}

I32
dopoptosub(pTHX_ I32 startingblock)
{
    dTHR;
    return dopoptosub_at(cxstack, startingblock);
}

PERL_CONTEXT*
upcontext(pTHX_ I32 count)
{
    PERL_SI *top_si = PL_curstackinfo;
    I32 cxix = dopoptosub(cxstack_ix);
    PERL_CONTEXT *cx;
    PERL_CONTEXT *ccstack = cxstack;
    I32 dbcxix;

    for (;;) {
        /* we may be in a higher stacklevel, so dig down deeper */
        while (cxix < 0 && top_si->si_type != PERLSI_MAIN) {
            top_si = top_si->si_prev;
            ccstack = top_si->si_cxstack;
            cxix = dopoptosub_at(ccstack, top_si->si_cxix);
        }
        if (cxix < 0) {
            return (PERL_CONTEXT *)0;
        }
        if (PL_DBsub && cxix >= 0 &&
                ccstack[cxix].blk_sub.cv == GvCV(PL_DBsub))
            count++;
        if (!count--)
            break;
        cxix = dopoptosub_at(ccstack, cxix - 1);
    }
    cx = &ccstack[cxix];
    if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
        dbcxix = dopoptosub_at(ccstack, cxix - 1);
        /* We expect that ccstack[dbcxix] is CXt_SUB, anyway, the
           field below is defined for any cx. */
        if (PL_DBsub && dbcxix >= 0 && ccstack[dbcxix].blk_sub.cv == GvCV(PL_DBsub))
            cx = &ccstack[dbcxix];
    }
    return cx;
}

/* inspired (loosely) by pp_wantarray */

U8
want_gimme (I32 uplevel)
{
    PERL_CONTEXT* cx = upcontext(uplevel);
    if (!cx) {
	warn("want_scalar: gone too far up the stack");
	return 0;
    }
    return cx->blk_gimme;
}

/* end thievery and "inspiration" */

OP*
find_parent_from(OP* start, OP* next, OP* parent)
{
    OP *o, *r;
    
    // printf("Looking for next: 0x%x\n", next);
    for (o = start; o; o = o->op_sibling) {
	// printf("(0x%x) %s\n", o, PL_op_name[o->op_type]);
    	if (o->op_type == OP_ENTERSUB && o->op_next == next)
	    return parent;

	if (o->op_flags & OPf_KIDS) {
	    r = find_parent_from(cUNOPo->op_first, next, o);
	    if (r) {
		if (r->op_type == OP_NULL || r->op_type == OP_SCOPE)
		    return o;
		else
		     return r;
	    }
	}
    }
    return Nullop;
}

/** Return the parent of the OP_ENTERSUB, or the grandparent if the parent
 *  is an OP_NULL or OP_SCOPE. If the parent precedes the last COP, then return Nullop.
 *  (In that last case, we must be in void context.)
 */
OP*
parent_op (I32 uplevel, OP** return_op_out)
{
    OP* return_op = Nullop;
    PERL_CONTEXT* cx = upcontext(uplevel);
    COP* prev_cop;
    
    if (!cx) {
	warn("want_scalar: gone too far up the context stack");
	return 0;
    }
    if (uplevel > PL_retstack_ix) {
	warn("want_scalar: gone too far up the return stack");
	return 0;
    }
    
    return_op = PL_retstack[PL_retstack_ix - uplevel - 1];
    prev_cop = cx->blk_oldcop;
    
    if (return_op_out)
	*return_op_out = return_op;

    return find_parent_from((OP*)prev_cop, return_op, Nullop);
}

/* forward declaration - mutual recursion */
I32 count_list (OP* parent, OP* returnop);

I32 count_slice (OP* o) {
    OP* pm = cUNOPo->op_first;
    OP* l  = Nullop;
    
    if (pm->op_type != OP_PUSHMARK)
	die("%s", "Want panicked: slice doesn't start with pushmark\n");
	
    if ( (l = pm->op_sibling) && (l->op_type == OP_LIST))
	return count_list(l, Nullop);

    else if (l)
	switch (l->op_type) {
	case OP_RV2AV:
	case OP_RV2HV:
	    return 0;
	case OP_HSLICE:
	case OP_ASLICE:
	    return count_slice(l);
	case OP_STUB:
	    return 1;
	default:
	    die("Want panicked: Unexpected op in slice (%s)\n", PL_op_name[l->op_type]);
	}
	
    else
	die("Want panicked: Nothing follows pushmark in slice\n");
}

/** Count the number of children of this OP.
 *  Except if any of them is OP_RV2AV or OP_ENTERSUB, return 0 instead.
 *  Also, stop counting if an OP_ENTERSUB is reached whose op_next is <returnop>.
 */
I32
count_list (OP* parent, OP* returnop)
{
    OP* o;
    I32 i = 0;
    
    if (! (parent->op_flags & OPf_KIDS))
	return 0;
	
    for(o = cUNOPx(parent)->op_first; o; o=o->op_sibling) {
	if (returnop && o->op_type == OP_ENTERSUB && o->op_next == returnop)
	    return i;
	if (o->op_type == OP_RV2AV || o->op_type == OP_RV2HV || o->op_type == OP_ENTERSUB)
	    return 0;
	
	if (o->op_type == OP_HSLICE || o->op_type == OP_ASLICE) {
	    I32 slice_length = count_slice(o);
	    if (slice_length == 0)
		return 0;
	    else
		i += slice_length - 1;
	}
	else ++i;
    }

    return i;
}

MODULE = Want		PACKAGE = Want		
PROTOTYPES: ENABLE

SV*
wantarray_up(uplevel)
I32 uplevel;
  PREINIT:
    U8 gimme = want_gimme(uplevel);
  CODE:
    switch(gimme) {
      case G_ARRAY:
        RETVAL = &PL_sv_yes;
        break;
      case G_SCALAR:
        RETVAL = &PL_sv_no;
        break;
      default:
        RETVAL = &PL_sv_undef;
    }
  OUTPUT:
    RETVAL

U8
want_lvalue(uplevel)
I32 uplevel;
  PREINIT:
    PERL_CONTEXT* cx;
  CODE:
    cx = upcontext(uplevel);
    if (!cx) {
      warn("Want::want_lvalue: gone too far up the stack");
      RETVAL = 0;
    }
    else if (!CvLVALUE(cx->blk_sub.cv)) {
      warn("Want: not an lvalue subroutine");
      RETVAL = 0;
    }
    else
      RETVAL = cx->blk_sub.lval;
  OUTPUT:
    RETVAL


char*
parent_op_name(uplevel)
I32 uplevel;
  PREINIT:
    OP* o = parent_op(uplevel, 0);
  CODE:
    RETVAL = o ? PL_op_name[o->op_type] : "(none)";
  OUTPUT:
    RETVAL

I32
want_count(uplevel)
I32 uplevel;
  PREINIT:
    OP* returnop;
    OP* o = parent_op(uplevel, &returnop);
    U8 gimme = want_gimme(uplevel);
  CODE:
    if (o && o->op_type == OP_AASSIGN) {
	I32 lhs = count_list(cBINOPo->op_last, Nullop   );
	I32 rhs = count_list(cBINOPo->op_first, returnop);
	if      (lhs == 0) RETVAL = -1;		/* (..@x..) = (..., foo(), ...); */
	else if (rhs == 0) RETVAL =  0;		/* (...) = (@x, foo()); */
	else RETVAL = lhs - rhs;
    }
    else switch(gimme) {
      case G_ARRAY:
        RETVAL = -1;
        break;
      case G_SCALAR:
        RETVAL = 1;
        break;
      default:
        RETVAL = 0;
    }
  OUTPUT:
    RETVAL
