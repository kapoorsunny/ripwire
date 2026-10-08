#include "monitor.h"

static int Sampler_scale( int v ) { return v * 2; }

static int
Sampler_average( Sampler* s )
{
    int sum = 0;
    for( int i = 0; i < s->count; i++ )
    {
        sum += Sampler_scale( s->values[ i ] );
    }
    return s->count > 0 ? sum / s->count : 0;
}

/* Legal C with the struct defined in the return type: both definitions are extent-suspect (head). */
struct SampleWindow
{
    int lo;
    int hi;
} Sampler_window( Sampler* s )
{
    struct SampleWindow w;
    w.lo = 0;
    w.hi = Sampler_average( s );
    return w;
}
