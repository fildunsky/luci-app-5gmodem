import java.lang.reflect.*;
import java.util.*;

public class CellProbe {
    static Object invoke(Object target, String name, Object... args) throws Exception {
        for (Method m : target.getClass().getMethods()) {
            if (!m.getName().equals(name) || m.getParameterTypes().length != args.length) continue;
            try { m.setAccessible(true); return m.invoke(target, args); }
            catch (IllegalArgumentException e) { continue; }
        }
        throw new NoSuchMethodException(name);
    }
    static Object optional(Object target, String name, Object... args) {
        try { return invoke(target, name, args); } catch (Exception e) { return null; }
    }
    static void field(Map<String,Object> out, Object target, String method, String key) {
        Object v = optional(target, method);
        if (v == null) return;
        if (v instanceof Number && (((Number)v).longValue() == Integer.MAX_VALUE || ((Number)v).longValue() == Long.MAX_VALUE || ((Number)v).longValue() < 0)) return;
        out.put(key,v);
    }
    static Map<String,Object> identity(Object object) {
        Map<String,Object> out = new LinkedHashMap<>();
        if (object == null) return out;
        out.put("type",object.getClass().getSimpleName());
        String[][] fields = {{"getCi","ci"},{"getCid","cid"},{"getNci","nci"},{"getTac","tac"},{"getLac","lac"},{"getPci","pci"},{"getEarfcn","earfcn"},{"getNrarfcn","nrarfcn"},{"getArfcn","arfcn"},{"getUarfcn","uarfcn"},{"getBandwidth","bandwidth"},{"getMccString","mcc"},{"getMncString","mnc"},{"getBands","bands"}};
        for(String[] f:fields) field(out,object,f[0],f[1]);
        return out;
    }
    static String json(Object v) {
        if(v==null) return "null";
        if(v instanceof Number || v instanceof Boolean) return v.toString();
        if(v instanceof Map) { StringBuilder s=new StringBuilder("{"); String sep=""; for(Object entry:((Map<?,?>)v).entrySet()) { Map.Entry<?,?> e=(Map.Entry<?,?>)entry; s.append(sep).append(json(e.getKey())).append(':').append(json(e.getValue())); sep=","; } return s.append('}').toString(); }
        if(v instanceof Iterable) { StringBuilder s=new StringBuilder("["); String sep=""; for(Object e:(Iterable<?>)v) {s.append(sep).append(json(e));sep=",";}return s.append(']').toString(); }
        if(v.getClass().isArray()) { List<Object> a=new ArrayList<>();for(int i=0;i<Array.getLength(v);i++)a.add(Array.get(v,i));return json(a); }
        String s=v.toString(); StringBuilder out=new StringBuilder("\"");
        for(int i=0;i<s.length();i++){char c=s.charAt(i);if(c=='"'||c=='\\')out.append('\\').append(c);else if(c<32)out.append(String.format("\\u%04x",(int)c));else out.append(c);}return out.append('"').toString();
    }
    public static class Update extends android.telephony.TelephonyManager.CellInfoCallback {
        final java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);
        volatile List cells;
        volatile int error;
        public void onCellInfo(List value) { cells=value; done.countDown(); }
        public void onError(int code, Throwable detail) { error=code; done.countDown(); }
    }
    static List<Object> cells(Object all) {
        List<Object> result=new ArrayList<>();
        if(all instanceof Iterable)for(Object cell:(Iterable<?>)all){Map<String,Object> c=new LinkedHashMap<>();c.put("registered",optional(cell,"isRegistered"));c.put("timestamp_ns",optional(cell,"getTimeStamp"));c.put("status",optional(cell,"getCellConnectionStatus"));c.put("identity",identity(optional(cell,"getCellIdentity")));Object signal=optional(cell,"getCellSignalStrength");
            for(String[] f:new String[][]{{"getDbm","dbm"},{"getRssi","rssi"},{"getRsrp","rsrp"},{"getRsrq","rsrq"},{"getRssnr","sinr"},{"getSsRsrp","ss_rsrp"},{"getSsRsrq","ss_rsrq"},{"getSsSinr","ss_sinr"}}) {
                Object v=optional(signal,f[0]);if(v instanceof Number && ((Number)v).longValue()!=Integer.MAX_VALUE)c.put(f[1],v);
            }
            result.add(c);}
        return result;
    }
    static int subscriptionId(String method) throws Exception {
        return ((Number)Class.forName("android.telephony.SubscriptionManager").getMethod(method).invoke(null)).intValue();
    }
    static boolean canSwitch(Object context, Object subscriptions) {
        try {
            subscriptions.getClass().getMethod("setDefaultDataSubId",int.class);
            return ((Number)invoke(context,"checkSelfPermission","android.permission.MODIFY_PHONE_STATE")).intValue()==0;
        } catch(Exception e) { return false; }
    }
    static Map<String,Object> simIdentity(Object manager, int sub) throws Exception {
        Object tm=invoke(manager,"createForSubscriptionId",sub);
        Map<String,Object> out=new LinkedHashMap<>();
        for(String[] f:new String[][]{{"getSubscriberId","imsi"},{"getSimSerialNumber","iccid"},{"getImei","imei"}}) {
            Object value=optional(tm,f[0]);
            if(value!=null && value.toString().matches("[0-9A-Fa-f]{5,22}"))out.put(f[1],value.toString());
        }
        return out;
    }
    static Map<String,Object> slots(Object context, Object manager, String[] args) throws Exception {
        Object subscriptions=invoke(context,"getSystemService","telephony_subscription_service");
        Object list=invoke(subscriptions,"getActiveSubscriptionInfoList");
        boolean writable=canSwitch(context,subscriptions);
        List<Map<String,Object>> slots=new ArrayList<>();
        int requested=-1;
        boolean setting="set-data".equals(args[0]);
        int targetSlot=setting ? Integer.parseInt(args[1]) : -1;
        if(setting && (targetSlot<1 || targetSlot>8))throw new IllegalArgumentException("Invalid SIM slot");
        if(list instanceof Iterable)for(Object info:(Iterable<?>)list) {
            int slot=((Number)invoke(info,"getSimSlotIndex")).intValue();
            int sub=((Number)invoke(info,"getSubscriptionId")).intValue();
            if(slot<0 || sub<0)continue;
            Map<String,Object> item=new LinkedHashMap<>();
            item.put("id",Integer.toString(slot+1));item.put("label","SIM "+(slot+1));item.put("present","1");
            item.put("subscription_id",Integer.toString(sub));item.putAll(simIdentity(manager,sub));
            Object tm=invoke(manager,"createForSubscriptionId",sub);item.put("data_enabled",optional(tm,"isDataEnabled"));item.put("data_state",optional(tm,"getDataState"));slots.add(item);
            if(slot+1==targetSlot)requested=sub;
        }
        int previous=subscriptionId("getDefaultDataSubscriptionId");
        if(setting) {
            if(!writable)throw new SecurityException("Mobile-data SIM switching is not permitted");
            if(requested<0)throw new IllegalArgumentException("SIM slot has no active subscription");
            if(requested!=previous)invoke(subscriptions,"setDefaultDataSubId",requested);
            for(int i=0;i<8 && subscriptionId("getDefaultDataSubscriptionId")!=requested;i++)Thread.sleep(250);
        }
        int selected=subscriptionId("getDefaultDataSubscriptionId");
        int active=subscriptionId("getActiveDataSubscriptionId");
        Map<String,Object> out=new LinkedHashMap<>();out.put("type","android");out.put("slots",slots);
        out.put("writable",writable);out.put("default_data_subscription",selected);out.put("active_data_subscription",active);
        for(Map<String,Object> item:slots)if(Integer.toString(active).equals(item.get("subscription_id")))out.put("active",item.get("id"));
        if(setting){out.put("ok",selected==requested);out.put("previous_subscription",previous);out.put("pending",active!=requested);if(selected!=requested)out.put("error","Data SIM selection was not confirmed");}
        return out;
    }
    // ---- Radio access: allowed network types and band selection -------------------------------
    // GERAN=1, UTRAN=2, EUTRAN=3, NGRAN=6 (AccessNetworkConstants.AccessNetworkType)
    static final int[] RANS = {1, 2, 3, 6};
    static final long ALL_TYPES = (1L << 20) - 1;

    static int radioSub(Object context, String arg) throws Exception {
        Object subscriptions = invoke(context, "getSystemService", "telephony_subscription_service");
        int sub = "active".equals(arg) ? subscriptionId("getActiveDataSubscriptionId") : Integer.parseInt(arg);
        if (sub < 0) sub = subscriptionId("getDefaultDataSubscriptionId");
        Object list = invoke(subscriptions, "getActiveSubscriptionInfoList");
        if (list instanceof Iterable) for (Object info : (Iterable<?>) list)
            if (((Number) invoke(info, "getSubscriptionId")).intValue() == sub) return sub;
        throw new IllegalArgumentException("Subscription is not active");
    }

    static Map<Integer, SortedSet<Integer>> readBands(Object tm) throws Exception {
        Map<Integer, SortedSet<Integer>> out = new TreeMap<>();
        Object list = invoke(tm, "getSystemSelectionChannels");
        if (list instanceof Iterable) for (Object spec : (Iterable<?>) list) {
            int ran = ((Number) invoke(spec, "getRadioAccessNetwork")).intValue();
            int[] bands = (int[]) invoke(spec, "getBands");
            SortedSet<Integer> set = out.get(ran);
            if (set == null) { set = new TreeSet<>(); out.put(ran, set); }
            for (int b : bands) set.add(b);
        }
        return out;
    }

    // Some modems (Samsung's Exynos) answer getSystemSelectionChannels with "Failed to retrieve system selecton
    // channels": the band API does not exist there. The network mode is a separate call and still works.
    static boolean bandsAvailable(Object tm) {
        try { readBands(tm); return true; } catch (Throwable e) { return false; }
    }

    static Object specifier(int ran, Collection<Integer> bands) throws Exception {
        int[] values = new int[bands.size()];
        int i = 0;
        for (int b : bands) values[i++] = b;
        return Class.forName("android.telephony.RadioAccessSpecifier")
            .getConstructor(int.class, int[].class, int[].class).newInstance(ran, values, new int[0]);
    }

    // The callback is not reliably delivered on every modem, so success is confirmed by reading the selection back.
    static void writeBands(Object tm, List<Object> specifiers) throws Exception {
        java.util.concurrent.Executor inline = new java.util.concurrent.Executor() { public void execute(Runnable task) { task.run(); } };
        java.util.function.Consumer<List<Object>> ignore = new java.util.function.Consumer<List<Object>>() { public void accept(List<Object> value) { } };
        invoke(tm, "setSystemSelectionChannels", specifiers, inline, ignore);
    }

    static void printRadio(Object tm, int sub, boolean writable) throws Exception {
        StringBuilder out = new StringBuilder();
        out.append("SUB|").append(sub).append('\n');
        out.append("WRITABLE|").append(writable ? 1 : 0).append('\n');
        Object allowed = optional(tm, "getAllowedNetworkTypesForReason", 0);
        if (allowed instanceof Number) out.append("ALLOWED|").append(((Number) allowed).longValue()).append('\n');
        Object rat = optional(tm, "getDataNetworkType");
        if (rat instanceof Number) out.append("RAT|").append(((Number) rat).intValue()).append('\n');
        Object dataState = optional(tm, "getDataState");
        if (dataState instanceof Number) out.append("DATA|").append(((Number) dataState).intValue()).append('\n');
        Object dataEnabled = optional(tm, "isDataEnabled");
        if (dataEnabled instanceof Boolean) out.append("DATA_ENABLED|").append(((Boolean) dataEnabled) ? 1 : 0).append('\n');
        Map<Integer, SortedSet<Integer>> bands = null;
        try { bands = readBands(tm); } catch (Throwable e) { bands = null; }
        if (bands == null) out.append("BANDS_UNSUPPORTED|1\n");
        else for (int ran : RANS) {
            out.append("BANDS|").append(ran).append('|');
            String sep = "";
            SortedSet<Integer> set = bands.get(ran);
            if (set != null) for (int b : set) { out.append(sep).append(b); sep = " "; }
            out.append('\n');
        }
        out.append("__5GM_RADIO_END__\n");
        System.out.print(out);
    }

    static boolean sameBands(Map<Integer, SortedSet<Integer>> a, Map<Integer, SortedSet<Integer>> b, Collection<Integer> rans) {
        for (int ran : rans) {
            SortedSet<Integer> x = a.get(ran), y = b.get(ran);
            if (x == null) x = new TreeSet<>();
            if (y == null) y = new TreeSet<>();
            if (!x.equals(y)) return false;
        }
        return true;
    }

    static void radio(Object context, Object manager, String[] args) throws Exception {
        String action = args[0];
        int sub = radioSub(context, args.length > 1 ? args[1] : "active");
        Object tm = invoke(manager, "createForSubscriptionId", sub);
        boolean writable = ((Number) invoke(context, "checkSelfPermission", "android.permission.MODIFY_PHONE_STATE")).intValue() == 0;
        if ("set-mode".equals(action)) {
            if (!writable) throw new SecurityException("Network mode switching is not permitted");
            long mask = Long.parseLong(args[2]);
            if (mask <= 0 || (mask & ~ALL_TYPES) != 0) throw new IllegalArgumentException("Invalid network type mask");
            invoke(tm, "setAllowedNetworkTypesForReason", 0, mask);
            for (int i = 0; i < 12; i++) {
                Object now = optional(tm, "getAllowedNetworkTypesForReason", 0);
                if (now instanceof Number && ((Number) now).longValue() == mask) break;
                Thread.sleep(250);
            }
        } else if ("set-bands".equals(action)) {
            if (!writable) throw new SecurityException("Band selection is not permitted");
            if (!bandsAvailable(tm)) throw new UnsupportedOperationException("This phone does not support band selection");
            Map<Integer, SortedSet<Integer>> want = new TreeMap<>();
            for (int i = 2; i < args.length; i++) {
                String[] kv = args[i].split("=", 2);
                int ran = Integer.parseInt(kv[0]);
                if (ran != 1 && ran != 2 && ran != 3 && ran != 6) throw new IllegalArgumentException("Invalid radio access network");
                SortedSet<Integer> set = new TreeSet<>();
                for (String token : kv[1].split(",")) {
                    int band = Integer.parseInt(token);
                    if (band < 1 || band > 511) throw new IllegalArgumentException("Invalid band");
                    set.add(band);
                }
                if (set.isEmpty()) throw new IllegalArgumentException("Empty band list");
                want.put(ran, set);
            }
            if (want.isEmpty()) throw new IllegalArgumentException("No bands requested");
            // The call replaces the whole selection and a network that is left out is switched off, so the
            // networks that were not named keep the list they have now. The modem does not accept explicit
            // lists for GSM band 12 (1800) and UMTS band 26: they are only available in the unrestricted state.
            Map<Integer, SortedSet<Integer>> current = readBands(tm);
            List<Object> specifiers = new ArrayList<>();
            for (int ran : RANS) {
                SortedSet<Integer> set = want.containsKey(ran) ? want.get(ran) : current.get(ran);
                if (set != null && !set.isEmpty()) specifiers.add(specifier(ran, set));
            }
            writeBands(tm, specifiers);
            Map<Integer, SortedSet<Integer>> expected = new TreeMap<>();
            for (int ran : want.keySet()) {
                SortedSet<Integer> set = new TreeSet<>(want.get(ran));
                if (ran == 1) set.remove(12);
                if (ran == 2) set.remove(26);
                expected.put(ran, set);
            }
            for (int i = 0; i < 16; i++) {
                if (sameBands(readBands(tm), expected, expected.keySet())) break;
                Thread.sleep(250);
            }
        } else if ("reset-bands".equals(action)) {
            if (!writable) throw new SecurityException("Band selection is not permitted");
            // Nothing to reset where the band API is missing: the readback below reports it.
            if (bandsAvailable(tm)) {
                writeBands(tm, new ArrayList<Object>());
                Thread.sleep(1500);
            }
        } else if (!"radio".equals(action)) {
            throw new IllegalArgumentException("Unknown radio action");
        }
        printRadio(tm, sub, writable);
    }

    public static void main(String[] args) {
        Map<String,Object> output=new LinkedHashMap<>();
        try {
            Class<?> initializer=Class.forName("android.telephony.TelephonyFrameworkInitializer");
            Class<?> serviceManager=Class.forName("android.os.TelephonyServiceManager");
            if(initializer.getMethod("getTelephonyServiceManager").invoke(null)==null)
                initializer.getMethod("setTelephonyServiceManager",serviceManager).invoke(null,serviceManager.newInstance());
            Class<?> looper=Class.forName("android.os.Looper");
            if(looper.getMethod("myLooper").invoke(null)==null)looper.getMethod("prepareMainLooper").invoke(null);
            Object thread=Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
            Object context=invoke(thread,"getSystemContext");
            context=invoke(context,"createPackageContext","com.android.shell",0);
            Class<?> builderClass=Class.forName("android.content.AttributionSource$Builder");
            Object builder=builderClass.getConstructor(int.class).newInstance(2000);
            invoke(builder,"setPackageName","com.android.shell");
            Object attribution=invoke(builder,"build");
            Field attributionField=context.getClass().getDeclaredField("mAttributionSource");
            attributionField.setAccessible(true);attributionField.set(context,attribution);
            Object manager=invoke(context,"getSystemService","phone");
            if(args.length>0 && ("slots".equals(args[0]) || "set-data".equals(args[0]))) {
                output=slots(context,manager,args);System.out.println(json(output));System.exit(0);return;
            }
            if(args.length>0 && ("radio".equals(args[0]) || "set-mode".equals(args[0]) || "set-bands".equals(args[0]) || "reset-bands".equals(args[0]))) {
                try { radio(context,manager,args); }
                catch(Throwable e){ Throwable r=e; while(r.getCause()!=null)r=r.getCause(); System.out.println("ERROR|"+r.getClass().getSimpleName()+": "+String.valueOf(r.getMessage()).replaceAll("[\\r\\n|]"," ")); }
                System.exit(0);return;
            }
            Object subscriptions=invoke(context,"getSystemService","telephony_subscription_service");
            output.put("can_switch_data",canSwitch(context,subscriptions));
            output.put("elapsed_ms",Class.forName("android.os.SystemClock").getMethod("elapsedRealtime").invoke(null));
            List<Object> states=new ArrayList<>();
            for(String arg:args) {
                int sub=Integer.parseInt(arg); Object tm=invoke(manager,"createForSubscriptionId",sub);
                Map<String,Object> state=new LinkedHashMap<>();state.put("sub_id",sub);state.putAll(simIdentity(manager,sub));
                Object service=invoke(tm,"getServiceState");
                List<Object> registrations=new ArrayList<>();
                Object infos=optional(service,"getNetworkRegistrationInfoList");
                if(infos instanceof Iterable)for(Object info:(Iterable<?>)infos){Map<String,Object> item=new LinkedHashMap<>();field(item,info,"getDomain","domain");field(item,info,"getTransportType","transport");item.put("identity",identity(optional(info,"getCellIdentity")));registrations.add(item);}
                state.put("registrations",registrations);
                state.put("volte",optional(tm,"isVolteAvailable"));state.put("wfc",optional(tm,"isWifiCallingAvailable"));
                Update update=new Update();
                java.util.concurrent.Executor executor=new java.util.concurrent.Executor(){public void execute(Runnable task){task.run();}};
                invoke(tm,"requestCellInfoUpdate",executor,update);
                update.done.await(4,java.util.concurrent.TimeUnit.SECONDS);
                state.put("update_error",update.error);state.put("cells",cells(update.cells));
                states.add(state);
            }
            output.put("subscriptions",states);
            output.put("elapsed_ms",Class.forName("android.os.SystemClock").getMethod("elapsedRealtime").invoke(null));
        } catch(Throwable e){while(e.getCause()!=null)e=e.getCause();output.put("error",e.getClass().getName()+": "+e.getMessage());}
        System.out.println(json(output));System.exit(0);
    }
}
