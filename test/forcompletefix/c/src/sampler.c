#include "monitor.h"

int Probe_read( Probe* p )
{
    return p->raw * 2 + p->id;
}

static void Sampler_collectOne( Sampler* s, int i )
{
    s->values[ i ] = Probe_read( &s->probes[ i ] );
}

static void Sampler_prune( Sampler* s )
{
    while( s->count > 0 && s->values[ s->count - 1 ] < 0 )
    {
        s->count--;
    }
}

/* Collect one reading from every probe, then drop trailing invalid readings. */
void Sampler_collectAll( Sampler* s )
{
    for( int i = 0; i < s->count; i++ )
    {
        Sampler_collectOne( s, i );
    }
    Sampler_prune( s );
}
