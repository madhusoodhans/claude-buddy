// Desktop renderer for the Claude Buddy pages (see render.sh). Stubs the board in inc/.
#include "model.h"
#include "ui.h"
uint32_t simMillis = 0;
bool soundOn = false;
namespace board { GFXcanvas16 canvas; GFXcanvas16* fb = &canvas; }
using namespace board;
static void header(int page){ // simple stand-in for main.cpp chrome
  fb->fillRect(0,0,LCD_W,ui::HEADER_H,0);
  aa::text(120,32,"12:42",fontClock,ui::TEXT,aa::Align::Center);
  ui::spark(120-30-16,23,7,0.5,ui::CLAY,2.2f); aa::disc(120+30+14,23,3.5f,ui::BLUE);
  for(int i=0;i<3;i++){int x=120+(i-1)*14; if(i==page) aa::roundRect(x-8,285,16,6,3,ui::TEXT); else aa::disc(x,288,3,ui::FAINT);}
}
static void save(const char* name){
  FILE* f=fopen(name,"wb"); fprintf(f,"P6 %d %d 255\n",LCD_W,LCD_H);
  for(int i=0;i<LCD_W*LCD_H;i++){ uint16_t v=fb->buf[i];
    // corner mask: the glass hides anything beyond the radius-40 corners
    int x=i%LCD_W,y=i/LCD_W; int cx=x<40?40:(x>=LCD_W-40?LCD_W-41:x), cy=y<40?40:(y>=LCD_H-40?LCD_H-41:y);
    bool hidden=(x-cx)*(x-cx)+(y-cy)*(y-cy)>40*40;
    unsigned char rgb[3]={(unsigned char)((v>>11)<<3),(unsigned char)(((v>>5)&63)<<2),(unsigned char)((v&31)<<3)};
    if(hidden){rgb[0]=rgb[1]=rgb[2]=60;}
    fwrite(rgb,1,3,f);} fclose(f);
}
int main(){
  simMillis=500000;
  handleMessage("T|1762862400|19800|1|Madhu's MacBook");
  handleMessage("U|1|42|175|61|1500|Pro|20|");
  handleMessage("D|23|187|9|842|61234|0,0,0,0,0,0,0,0,2,14,30,22,8,0,12,40,35,28,9,0,0,0,0,0|diy-pet");
  handleMessage("A|12:40|Edit face.cpp"); handleMessage("A|12:41|Bash: ./pet.sh build");
  const char* moods[]={"S|1|134|2|diy-pet|Editing buddy/face.cpp","S|2|5|2|diy-pet|Needs permission: Bash","S|3|1|2|diy-pet|Finished in 6m 12s","S|0|300|2|diy-pet|"};
  const char* names[]={"face_working","face_waiting","face_done","face_idle"};
  for(int i=0;i<4;i++){ handleMessage(moods[i]); face::moodChanged(Mood::Idle,activity.mood,simMillis); simMillis+=700;
    fb->fillScreen(0); face::draw(simMillis,true); header(0); char n[64]; snprintf(n,64,"%s.ppm",names[i]); save(n);}
  fb->fillScreen(0); face::draw(simMillis,false); header(0); save("face_lost.ppm");
  fb->fillScreen(0); meters::draw(simMillis,true); header(1); save("meters.ppm");
  fb->fillScreen(0); day::draw(simMillis,true); header(2); save("day.ppm");
}
