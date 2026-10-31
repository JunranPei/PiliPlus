import android.graphics.SurfaceTexture;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.Looper;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;

public final class EmbeddedLifecycleProbe {
    static Class<?> helper;
    static boolean asyncInput;
    static final class Bridge {
        final Object object;
        Bridge(MediaCodec codec) {
            try { object=helper.getConstructor(MediaCodec.class,boolean.class).newInstance(codec,asyncInput); }
            catch(Exception e) { throw new IllegalStateException(e); }
        }
        Object call(String name,Class<?>[] types,Object...args) {
            try {return helper.getMethod(name,types).invoke(object,args);}
            catch(java.lang.reflect.InvocationTargetException e) {
                Throwable t=e.getCause();if(t instanceof RuntimeException)throw (RuntimeException)t;throw new IllegalStateException(t);
            } catch(Exception e) {throw new IllegalStateException(e);}
        }
        int dequeueInputBuffer(long us){return (Integer)call("dequeueInputBuffer",new Class[]{long.class},us);}
        int dequeueOutputBuffer(MediaCodec.BufferInfo info,long us){return (Integer)call("dequeueOutputBuffer",new Class[]{MediaCodec.BufferInfo.class,long.class},info,us);}
        MediaFormat getOutputFormat(){return (MediaFormat)call("getOutputFormat",new Class[]{});}
        void queueInputBuffer(int i,int o,int s,long p,int f){call("queueInputBuffer",new Class[]{int.class,int.class,int.class,long.class,int.class},i,o,s,p,f);}
        void flush(){call("flush",new Class[]{});}
        void awaitActivity(long us){call("awaitActivity",new Class[]{long.class},us);}
        void close(){call("close",new Class[]{});}
        long[] snapshot(){return (long[])call("snapshot",new Class[]{});}
    }

    static class Data {
        MediaFormat format;
        ArrayList<CodecQueueProbe.Packet> packets = new ArrayList<>();
    }
    static Data read(String path, long targetUs) throws Exception {
        Data data = new Data(); MediaExtractor e = new MediaExtractor();
        try {
            e.setDataSource(path); int track = -1;
            for (int i=0;i<e.getTrackCount();i++) if ("video/hevc".equals(e.getTrackFormat(i).getString(MediaFormat.KEY_MIME))) {track=i;break;}
            if (track<0) throw new AssertionError("No HEVC");
            data.format=e.getTrackFormat(track);e.selectTrack(track);e.seekTo(targetUs,MediaExtractor.SEEK_TO_PREVIOUS_SYNC);
            ByteBuffer scratch=ByteBuffer.allocateDirect(4*1024*1024);int later=0;
            while (e.getSampleTime()>=0) {
                int size=e.readSampleData(scratch,0);if(size<0)break;
                long pts=e.getSampleTime();byte[] bytes=new byte[size];scratch.position(0);scratch.get(bytes);
                data.packets.add(new CodecQueueProbe.Packet(bytes,pts));
                if(pts>targetUs+2000000 && ++later>=16)break;
                e.advance();
            }
        } finally {e.release();}
        return data;
    }
    static boolean output(MediaCodec codec,Bridge bridge,JSONArray pts,long wait) {
        MediaCodec.BufferInfo info=new MediaCodec.BufferInfo();int index=bridge.dequeueOutputBuffer(info,wait);
        if(index==MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            if(bridge.getOutputFormat().getInteger(MediaFormat.KEY_WIDTH)!=852)throw new AssertionError("Unexpected format");
        } else if(index>=0) {
            if(info.size>0)pts.put(info.presentationTimeUs);
            codec.releaseOutputBuffer(index,false);
            return (info.flags&MediaCodec.BUFFER_FLAG_END_OF_STREAM)!=0;
        }
        return false;
    }
    static JSONArray decode(MediaCodec codec,Bridge bridge,Data data,boolean partial) {
        JSONArray pts=new JSONArray();int cursor=0;boolean inputEos=false,outputEos=false;
        long deadline=System.nanoTime()+30000000000L;
        while(!outputEos && System.nanoTime()<deadline) {
            outputEos=output(codec,bridge,pts,0);if(outputEos)break;
            if(partial && pts.length()>=1 && cursor>=4) return pts;
            if(!inputEos) {
                int index=bridge.dequeueInputBuffer(0);
                if(index>=0) {
                    if(cursor==data.packets.size()) {
                        bridge.queueInputBuffer(index,0,0,0,MediaCodec.BUFFER_FLAG_END_OF_STREAM);inputEos=true;
                    } else {
                        CodecQueueProbe.Packet p=data.packets.get(cursor++);
                        ByteBuffer b=codec.getInputBuffer(index);b.clear();b.put(p.bytes);
                        bridge.queueInputBuffer(index,0,p.bytes.length,p.pts,0);
                    }
                } else outputEos=output(codec,bridge,pts,8000);
            } else outputEos=output(codec,bridge,pts,8000);
        }
        if(!outputEos)throw new AssertionError("EOS timeout");
        return pts;
    }
    static void equal(JSONArray a,JSONArray b,String label)throws Exception {
        if(a.length()!=b.length())throw new AssertionError(label+" count "+a.length()+" != "+b.length());
        for(int i=0;i<a.length();i++)if(a.getLong(i)!=b.getLong(i))throw new AssertionError(label+" PTS mismatch at "+i);
    }
    public static void main(String[] args)throws Exception {
        if(Looper.getMainLooper()==null)Looper.prepareMainLooper();
        JSONObject report=new JSONObject();
        asyncInput=Boolean.parseBoolean(args[2]);
        report.put("asyncInput",asyncInput);
        ByteBuffer dex=ByteBuffer.wrap(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(args[1])));
        ClassLoader loader=new dalvik.system.InMemoryDexClassLoader(dex,ClassLoader.getSystemClassLoader());
        helper=loader.loadClass("com.personal.piliplus.PiliCodecCallbacks");
        if(helper.getClassLoader()!=loader)throw new AssertionError("Helper came from parent classpath");
        report.put("loadedFromEmbeddedDex",true);
        try {
            Data first=read(args[0],61500000),next=read(args[0],181500000);
            JSONObject referenceA=CodecQueueProbe.run(args[0],"sync",61500000);
            JSONObject referenceB=CodecQueueProbe.run(args[0],"sync",181500000);
            if(!referenceA.getBoolean("completed")||!referenceB.getBoolean("completed"))throw new AssertionError("Reference incomplete");
            MediaCodec codec=MediaCodec.createByCodecName("c2.goldfish.hevc.decoder");
            SurfaceTexture texture=new SurfaceTexture(false);android.view.Surface surface=new android.view.Surface(texture);
            Bridge bridge=new Bridge(codec);
            try {
                codec.configure(first.format,surface,null,0);codec.start();
                JSONArray a=decode(codec,bridge,first,false);equal(a,referenceA.getJSONArray("outputs"),"initial");
                report.put("initialEosFrames",a.length());
                bridge.flush();JSONArray b=decode(codec,bridge,next,false);equal(b,referenceB.getJSONArray("outputs"),"afterEosSeek");
                report.put("afterEosSeekFrames",b.length());
                bridge.flush();JSONArray partial=decode(codec,bridge,first,true);
                report.put("partialBeforeFlush",partial.length());
                bridge.flush();JSONArray again=decode(codec,bridge,next,false);equal(again,referenceB.getJSONArray("outputs"),"afterPartialSeek");
                report.put("afterPartialSeekFrames",again.length());
                bridge.flush();decode(codec,bridge,first,true);
                bridge.close();bridge.close();
                long[] state=bridge.snapshot();
                if(state[2]!=4||state[3]!=0||state[4]!=0||state[5]!=1||state[6]!=0||state.length!=15||state[7]!=(asyncInput?1:0)||state[11]!=0||state[12]!=0||state[13]!=0)throw new AssertionError("Close state");
                report.put("closedState",new JSONArray(state)).put("repeatClosePassed",true);
            } finally {bridge.close();codec.stop();codec.release();surface.release();texture.release();}
            // Cancellation wakes a decoder owner blocked before the codec starts.
            MediaCodec waitingCodec=MediaCodec.createByCodecName("c2.goldfish.hevc.decoder");
            Bridge waiting=new Bridge(waitingCodec);
            CountDownLatch entered=new CountDownLatch(1);AtomicReference<Throwable> wake=new AtomicReference<>();
            Thread waiter=new Thread(()->{entered.countDown();try{waiting.awaitActivity(-1);}catch(Throwable e){wake.set(e);}},"pili-cancel-waiter");
            try {
                waiter.start();if(!entered.await(2,TimeUnit.SECONDS))throw new AssertionError("Waiter not started");
                waiting.close();waiter.join(2000);
                if(waiter.isAlive()||!(wake.get() instanceof IllegalStateException))throw new AssertionError("Blocked owner not woken");
                report.put("blockedOwnerCancelled",true);
            } finally {waiting.close();waitingCodec.release();}
            report.put("passed",true);
        } catch(Throwable error){report.put("passed",false).put("exception",error.toString());error.printStackTrace(System.err);}
        System.out.println(report.toString());
    }
}
