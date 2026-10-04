#include <stdlib.h>
#include "monitor.h"

static void Monitor_refresh( Monitor* m )
{
    if( m->stale )
    {
        Sampler_collectAll( m->sampler );
        m->stale = 0;
    }
    Board_paint( m->board );
}

void Monitor_loop( Monitor* m )
{
    while( !m->quit )
    {
        Monitor_refresh( m );
        int key = Input_read();
        if( key == 'q' )
        {
            m->quit = 1;
        }
        else if( key >= 0 )
        {
            Board_onKey( m->board, key );
        }
    }
}

Monitor* Monitor_new( void )
{
    Monitor* m = calloc( 1, sizeof( Monitor ) );
    m->stale = 1;
    return m;
}

int Input_read( void )
{
    return -1;
}
