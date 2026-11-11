#pragma once
#include <Arduino.h>
namespace board {
constexpr int LCD_W=240, LCD_H=296, SAFE_X=26, CORNER_R=40;
constexpr uint16_t rgb(uint8_t r,uint8_t g,uint8_t b){ return ((r&0xf8)<<8)|((g&0xfc)<<3)|(b>>3); }
struct GFXcanvas16 { uint16_t buf[LCD_W*LCD_H]; uint16_t* getBuffer(){return buf;}
  void fillScreen(uint16_t c){ for(auto&p:buf)p=c; }
  void fillRect(int x,int y,int w,int h,uint16_t c){ for(int j=y;j<y+h;j++)for(int i=x;i<x+w;i++) if(i>=0&&i<LCD_W&&j>=0&&j<LCD_H) buf[j*LCD_W+i]=c; } };
extern GFXcanvas16* fb;
struct Note{uint16_t freq,ms;};
inline void sfx(std::initializer_list<Note>){}
}
