#ifndef MONITOR_H
#define MONITOR_H

typedef struct Probe { int id; int raw; } Probe;

typedef struct Sampler
{
    Probe* probes;
    int    values[ 16 ];
    int    count;
} Sampler;

typedef struct Gauge Gauge;
typedef void ( *GaugeDrawFn )( Gauge* g );

typedef struct GaugeStyle
{
    const char* label;
    GaugeDrawFn draw;
} GaugeStyle;

struct Gauge
{
    int         value;
    int         style;
    GaugeDrawFn paint;
};

typedef struct Widget Widget;
typedef struct WidgetClass
{
    void ( *onKey )( Widget* w, int key );
} WidgetClass;

struct Widget
{
    const WidgetClass* klass;
    void*              state;
};

typedef struct Board
{
    Widget* focus;
    Gauge*  gauges;
    int     gaugeCount;
} Board;

typedef struct Monitor
{
    Sampler* sampler;
    Board*   board;
    int      stale;
    int      quit;
} Monitor;

int  Probe_read( Probe* p );
void Sampler_collectAll( Sampler* s );
void Board_onKey( Board* b, int key );
void Board_paint( Board* b );
void Gauge_setStyle( Gauge* g, int style );
void Gauge_render( Gauge* g );
int  Input_read( void );
void Monitor_loop( Monitor* m );
Monitor* Monitor_new( void );

#endif
