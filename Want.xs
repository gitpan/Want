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
        /*case CXt_EVAL:*/
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
    return dopoptosub_at(aTHX_ cxstack, startingblock);
}

PERL_CONTEXT*
upcontext(pTHX_ I32 count)
{
    PERL_SI *top_si = PL_curstackinfo;
    I32 cxix = dopoptosub(aTHX_ cxstack_ix);
    PERL_CONTEXT *cx;
    PERL_CONTEXT *ccstack = cxstack;
    I32 dbcxix;

    for (;;) {
        /* we may be in a higher stacklevel, so dig down deeper */
        while (cxix < 0 && top_si->si_type != PERLSI_MAIN) {
            top_si = top_si->si_prev;
            ccstack = top_si->si_cxstack;
            cxix = dopoptosub_at(aTHX_ ccstack, top_si->si_cxix);
        }
        if (cxix < 0) {
            return (PERL_CONTEXT *)0;
        }
        if (PL_DBsub && cxix >= 0 &&
                ccstack[cxix].blk_sub.cv == GvCV(PL_DBsub))
            count++;
        if (!count--)
            break;
        cxix = dopoptosub_at(aTHX_ ccstack, cxix - 1);
    }
    cx = &ccstack[cxix];
    if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
        dbcxix = dopoptosub_at(aTHX_ ccstack, cxix - 1);
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
    PERL_CONTEXT* cx = upcontext(aTHX_ uplevel);
    if (!cx) {
	warn("want_scalar: gone too far up the stack");
	return 0;
    }
    return cx->blk_gimme;
}

/* end thievery and "inspiration" */

#define OPLIST_MAX 50
typedef struct {
    U16 numop_num;
    OP* numop_op;
} numop;

typedef struct {
    U16    length;
    numop  ops[OPLIST_MAX];
} oplist;

#define find_parent_from(start, next)	lastop(find_ancestors_from(start, next, 0))
#define new_oplist			(oplist*) malloc(sizeof(oplist))
#define init_oplist(l)			l->length = 0

numop*
lastnumop(oplist* l)
{
    U16 i = l->length;
    numop* ret;
    while (i-- > 0) {
	ret = &(l->ops)[i];
	if (ret->numop_op->op_type != OP_NULL && ret->numop_op->op_type != OP_SCOPE) {
	    return ret;
	}
    }
    return (numop*)0;
}

/* NB: unlike lastnumop, lastop frees the oplist */
OP*
lastop(oplist* l)
{
    U16 i = l->length;
    OP* ret;
    while (i-- > 0) {
	ret = (l->ops)[i].numop_op;
	if (ret->op_type != OP_NULL && ret->op_type != OP_SCOPE) {
	    free(l);
	    return ret;
	}
    }
    free(l);
    return Nullop;
}

oplist*
pushop(oplist* l, OP* o, U16 i)
{
    I16 len = l->length;
    if (o) {
	++ l->length;
	l->ops[len].numop_op  = o;
	l->ops[len].numop_num = -1;
    }
    if (len > 0)
	l->ops[len-1].numop_num = i;

    return l;
}

oplist*
find_ancestors_from(OP* start, OP* next, oplist* l)
{
    OP     *o;
    U16    cn = 0;
    U16    ll;
    
    if (!l) {
	l = new_oplist;
	init_oplist(l);
	ll = 0;
    }
    else ll = l->length;
    
    /*printf("Looking for next: 0x%x\n", next);*/
    for (o = start; o; o = o->op_sibling, ++cn) {
	/*printf("(0x%x) %s -> 0x%x\n", o, PL_op_name[o->op_type], o->op_next);*/

    	if (o->op_type == OP_ENTERSUB && o->op_next == next)
	    return pushop(l, Nullop, cn);

	if (o->op_flags & OPf_KIDS) {
	    U16 ll = l->length;
	
	    pushop(l, o, cn);
	    if (find_ancestors_from(cUNOPo->op_first, next, l))
		return l;
	    else
		l->length = ll;
	}

    }
    return 0;
}

/** Return the parent of the OP_ENTERSUB, or the grandparent if the parent
 *  is an OP_NULL or OP_SCOPE. If the parent precedes the last COP, then return Nullop.
 *  (In that last case, we must be in void context.)
 */
OP*
parent_op (I32 uplevel, OP** return_op_out)
{
    OP* return_op = Nullop;
    PERL_CONTEXT* cx = upcontext(aTHX_ uplevel);
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

    return find_parent_from((OP*)prev_cop, return_op);
}

/**
 * Return the whole oplist leading down to the subcall.
 * It's the caller's responsibility to free the returned oplist.
 */
oplist*
ancestor_ops (I32 uplevel, OP** return_op_out)
{
    OP* return_op = Nullop;
    PERL_CONTEXT* cx = upcontext(aTHX_ uplevel);
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

    return find_ancestors_from((OP*)prev_cop, return_op, 0);
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

    return -999;  /* Should never get here - silence compiler warning */
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
	
    /*printf("count_list: returnop = 0x%x\n", returnop);*/
    for(o = cUNOPx(parent)->op_first; o; o=o->op_sibling) {
	/*printf("\t%-8s\t(0x%x)\n", PL_op_name[o->op_type], o->op_next);*/
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

I32
countstack(I32 uplevel)
{
    PERL_CONTEXT* cx = upcontext(aTHX_ uplevel);
    I32 oldmarksp;
    I32 mark_from;
    I32 mark_to;

    if (!cx) return -1;

    oldmarksp = cx->blk_oldmarksp;
    mark_from = PL_markstack[oldmarksp];
    mark_to   = PL_markstack[oldmarksp+1];
    return (mark_to - mark_from);
}

AV*
copy_rvals(I32 uplevel, I32 skip)
{
    PERL_CONTEXT* cx = upcontext(aTHX_ uplevel);
    I32 oldmarksp;
    I32 mark_from;
    I32 mark_to;
    U32 i;
    AV* a;

    oldmarksp = cx->blk_oldmarksp;
    mark_from = PL_markstack[oldmarksp-1];
    mark_to   = PL_markstack[oldmarksp];

    /*printf("\t(%d -> %d) %d skipping %d\n", mark_from, mark_to, oldmarksp, skip);*/

    if (!cx) return Nullav;
    a = newAV();
    for(i=mark_from+1; i<=mark_to; ++i)
	if (skip-- <= 0) av_push(a, PL_stack_base[i]);
    /* printf("avlen = %d\n", av_len(a)); */

    return a;
}

AV*
copy_rval(I32 uplevel)
{
    PERL_CONTEXT* cx = upcontext(aTHX_ uplevel);
    I32 oldmarksp;
    AV* a;

    oldmarksp = cx->blk_oldmarksp;
    if (!cx) return Nullav;
    a = newAV();
    /* printf("oldmarksp = %d\n", oldmarksp); */
    av_push(a, PL_stack_base[PL_markstack[oldmarksp+1]]);

    return a;
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
    cx = upcontext(aTHX_ uplevel);
    if (!cx) {
      warn("Want::want_lvalue: gone too far up the stack");
      RETVAL = 0;
    }
    else if (!CvLVALUE(cx->blk_sub.cv)) {
      /* Not an lvalue subroutine */
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
    OP *first, *second;
  CODE:
    /* This is a bit of a cheat, admittedly... */
    if (o && o->op_type == OP_ENTERSUB && (first = cUNOPo->op_first)
          && (second = first->op_sibling) && second->op_sibling != Nullop)
      RETVAL = "method_call";
    else
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
	I32 lhs = count_list(cBINOPo->op_last,  Nullop  );
	I32 rhs = countstack(uplevel);
	if      (lhs == 0) RETVAL = -1;		/* (..@x..) = (..., foo(), ...); */
	else if (rhs >= lhs-1) RETVAL =  0;
	else RETVAL = lhs - rhs - 1;
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

bool
want_boolean(uplevel)
I32 uplevel;
  PREINIT:
    oplist* l = ancestor_ops(uplevel, 0);
    U16 i;
    bool truebool = TRUE, pseudobool = FALSE;
  CODE:
    for(i=0; i < l->length; ++i) {
      OP* o = l->ops[i].numop_op;
      U16 n = l->ops[i].numop_num;
      bool v = (OP_GIMME(o, -1) == G_VOID);

      /*printf("%-8s %c %d\n", PL_op_name[o->op_type], (v ? 'v' : ' '), n);*/

      switch(o->op_type) {
	case OP_NOT:
	case OP_XOR:
	  truebool = TRUE;
	  break;
	  
	case OP_AND:
	  if (truebool || v)
	    truebool = TRUE;
	  else
	    pseudobool = (pseudobool || n == 0);
	  break;
	  
	case OP_OR:
	  if (truebool || v)
	    truebool = TRUE;
	  else
	    truebool = FALSE;
	  break;

	case OP_COND_EXPR:
	  truebool = (truebool || n == 0);
	  break;
	
	case OP_NULL:
	  break;
	    
	default:
	  truebool   = FALSE;
	  pseudobool = FALSE;
      }
    }
    free(l);
    RETVAL = truebool || pseudobool;
  OUTPUT:
    RETVAL

SV*
want_assign(uplevel)
U32 uplevel;
  PREINIT:
    AV* r;
    oplist* os = ancestor_ops(uplevel, 0);
    numop* lno = os ? lastnumop(os) : (numop*)0;
    OPCODE type;
  CODE:
    if (lno) type = lno->numop_op->op_type;
    if (lno && (type == OP_AASSIGN || type == OP_SASSIGN) && lno->numop_num == 1)
      if (type == OP_AASSIGN) {
        OP* returnop = PL_retstack[PL_retstack_ix - uplevel - 1];
        I32 lhs_count = count_list(cBINOPx(lno->numop_op)->op_last,  returnop);
        if (lhs_count == 0) r = newAV();
        else {
          r = copy_rvals(uplevel, lhs_count-1);
        }
      }
      else r = copy_rval(uplevel);

    else {
      /* Not an assignment */
      r = Nullav;
    }
    
    RETVAL = r ? newRV_inc((SV*) r) : &PL_sv_undef;
    if (os) free(os);
  OUTPUT:
    RETVAL

void
double_return()
  PREINIT:
    PERL_CONTEXT *ourcx, *cx;
  PPCODE:
    ourcx = upcontext(aTHX_ 0);
    cx    = upcontext(aTHX_ 1);
    if (!cx)
        Perl_croak(aTHX_ "Can't return outside a subroutine");

    ourcx->cx_type = CXt_NULL;
    pop_return();

    return;
