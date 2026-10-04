#include "monitor.h"

typedef void ( *KeyAction )( Board* b );

static KeyAction keyTable[ 128 ];

static void actionCycleStyle( Board* b )
{
    for( int i = 0; i < b->gaugeCount; i++ )
    {
        Gauge_setStyle( &b->gauges[ i ], ( b->gauges[ i ].style + 1 ) % 3 );
    }
}

static void actionFreeze( Board* b )
{
    b->gaugeCount = 0;
}

void Keys_bind( void )
{
    keyTable[ 's' ] = actionCycleStyle;
    keyTable[ 'f' ] = actionFreeze;
}

static void BoardWidget_onKey( Widget* w, int key )
{
    KeyAction fn = keyTable[ key & 127 ];
    if( fn )
    {
        fn( ( Board* )w->state );
    }
}

const WidgetClass BoardWidget_class = { .onKey = BoardWidget_onKey };
