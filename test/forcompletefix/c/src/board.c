#include "monitor.h"

void Board_onKey( Board* b, int key )
{
    Widget* w = b->focus;
    if( w && w->klass->onKey )
    {
        w->klass->onKey( w, key );
    }
}

void Board_paint( Board* b )
{
    for( int i = 0; i < b->gaugeCount; i++ )
    {
        Gauge_render( &b->gauges[ i ] );
    }
}
