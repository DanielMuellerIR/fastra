#include <gtk/gtk.h>
#include <stdio.h>
#include <string.h>
static unsigned diagnostics;
static void log_message(const gchar *domain,GLogLevelFlags level,const gchar *message,gpointer unused){(void)level;(void)unused;diagnostics++;fprintf(stderr,"%s: %s\n",domain,message);}
static void report(GtkTextBuffer *b,const char *operation){GtkTextIter a,z;gtk_text_buffer_get_bounds(b,&a,&z);char *text=gtk_text_buffer_get_text(b,&a,&z,TRUE);char *slice=gtk_text_buffer_get_slice(b,&a,&z,TRUE);int count=gtk_text_buffer_get_char_count(b);printf("{\"operation\":\"%s\",\"charCount\":%d,\"textCStringBytes\":%zu,\"sliceCStringBytes\":%zu,\"diagnostics\":%u",operation,count,strlen(text),strlen(slice),diagnostics);if(count==3)printf(",\"textBytes\":[%u,%u,%u],\"sliceBytes\":[%u,%u,%u]",(unsigned char)text[0],(unsigned char)text[1],(unsigned char)text[2],(unsigned char)slice[0],(unsigned char)slice[1],(unsigned char)slice[2]);puts("}");g_free(text);g_free(slice);}
int main(void){gtk_init();g_log_set_handler("Gtk",G_LOG_LEVEL_CRITICAL|G_LOG_LEVEL_WARNING,log_message,NULL);GtkTextBuffer *b=gtk_text_buffer_new(NULL);const char input[3]={'A',0,'B'};gtk_text_buffer_set_text(b,input,3);report(b,"set_text");gtk_text_buffer_set_text(b,"",0);GtkTextIter i;gtk_text_buffer_get_start_iter(b,&i);gtk_text_buffer_insert(b,&i,input,3);report(b,"insert");g_object_unref(b);return 0;}
