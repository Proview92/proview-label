// Interface of the built-in printer service on Senraise handhelds (H10P / H10S and similar).
// Package, names and method ORDER must match the service exactly (binder transaction codes).
package recieptservice.com.recieptservice;

import recieptservice.com.recieptservice.PSAMCallback;
import recieptservice.com.recieptservice.PrintCallback;

interface PrinterInterface {
     void printEpson(in byte[] data);
     String getServiceVersion();
     void printText(String text);
     void printBitmap(in Bitmap pic);
     void printBarCode(String data, int symbology, int height, int width);
     void printQRCode(String data, int modulesize, int errorlevel);
     void setAlignment(int alignment);
     void setTextSize(float textSize);
     void nextLine(int line);
     void printTableText(in String[] text, in int[] weight, in int[] alignment);
     void setTextBold(boolean bold);
     // print service 8.x (read from an H10S, Nov 2026): beginWork holds the printer, endWork prints and reports the result.
     // Older services ignore the callback and never answer it.
     boolean beginWork();
     void endWork(in PrintCallback callback);
     void setDark(int value);
     void setLineHeight(float lineHeight);
     void setTextDoubleWidth(boolean enable);
     void setTextDoubleHeight(boolean enable);
     void printPDF417Code(String data, int modulesize, int errorlevel);
     void setCode(String code);
     void print128BarCode(String data, int type, int height, int width);
     boolean getScannerStatus();
     void checkPSAMCard(int timeout, in PSAMCallback callback);
     void activatePSAMCard(int timeout, in PSAMCallback callback);
     void deactivatePSAMCard(int timeout, in PSAMCallback callback);
     void transmitPSAMCard(int timeout, in byte[] data, PSAMCallback callback);
     String getSN();
}
