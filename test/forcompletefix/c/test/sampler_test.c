#include "../src/monitor.h"

int test_collect_all( void )
{
    Probe   probes[ 2 ] = { { 1, 2 }, { 2, 3 } };
    Sampler s = { probes, { 0 }, 2 };
    Sampler_collectAll( &s );
    return s.values[ 0 ] == 5 ? 0 : 1;
}
