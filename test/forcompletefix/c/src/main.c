#include "monitor.h"

int main( int argc, char** argv )
{
    ( void )argc;
    ( void )argv;
    Monitor* m = Monitor_new();
    Monitor_loop( m );
    return 0;
}
