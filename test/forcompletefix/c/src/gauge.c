#include <stdio.h>
#include "monitor.h"

static void Gauge_drawBar( Gauge* g )
{
    for( int i = 0; i < g->value; i++ )
    {
        putchar( '|' );
    }
}

static void Gauge_drawText( Gauge* g )
{
    printf( "%d", g->value );
}

static void Gauge_drawDots( Gauge* g )
{
    for( int i = 0; i < g->value; i += 10 )
    {
        putchar( '.' );
    }
}

const GaugeStyle Gauge_modes[] = {
    { .label = "bar",  .draw = Gauge_drawBar },
    { .label = "text", .draw = Gauge_drawText },
    { .label = "dots", .draw = Gauge_drawDots },
};

void Gauge_setStyle( Gauge* g, int style )
{
    g->style = style;
    g->paint = Gauge_modes[ style ].draw;
}

void Gauge_render( Gauge* g )
{
    g->paint( g );
}
