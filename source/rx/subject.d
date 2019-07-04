/+++++++++++++++++++++++++++++
 + This module defines the Subject and some implements.
 +/
module rx.subject;

import rx.disposable;
import rx.observer;
import rx.contextobserver;
import rx.observable;
import rx.util : assumeThreadLocal;

import core.atomic : atomicLoad, cas;
import std.range : put;
import std.algorithm.searching : countUntil;

///Represents an object that is both an observable sequence as well as an observer.
interface Subject(E) : Observer!E, Observable!E
{
}

///Represents an object that is both an observable sequence as well as an observer. Each notification is broadcasted to all subscribed observers.
class SubjectObject(E) : Subject!E
{
    alias ElementType = E;

public:
    ///
    this()
    {
      _observer = cast(shared) NopObserver!E.instance;
    }

public:
    ///
    void put(E obj)
    {
      auto temp = assumeThreadLocal(atomicLoad(_observer));
      .put(temp, obj);
    }
    ///
    void completed()
    {
        shared(Observer!E) oldObserver = void;
        shared(Observer!E) newObserver = cast(shared) DoneObserver!E.instance;
        Observer!E temp = void;
        do
        {
            oldObserver = _observer;
            temp = assumeThreadLocal(atomicLoad(oldObserver));
            if (cast(DoneObserver!E) temp)
                break;
        }
        while (!cas(&_observer, oldObserver, newObserver));
        temp.completed();
    }
    ///
    void failure(Exception error)
    {
        shared(Observer!E) oldObserver = void;
        shared(Observer!E) newObserver = cast(shared) new DoneObserver!E(error);
        Observer!E temp = void;
        do
        {
            oldObserver = _observer;
            temp = assumeThreadLocal(atomicLoad(oldObserver));
            if (cast(DoneObserver!E) temp)
                break;
        }
        while (!cas(&_observer, oldObserver, newObserver));
        temp.failure(error);
    }

    ///
    Disposable subscribe(T)(T observer)
    {
        return subscribe(observerObject!E(observer));
    }
    ///
    Disposable subscribe(Observer!E observer)
    {
        shared(Observer!E) oldObserver = void;
        shared(Observer!E) newObserver = void;
        do
        {
            // access current observer(s) in a thread safe way
            oldObserver = _observer;
            auto temp = assumeThreadLocal(atomicLoad(oldObserver));

            // depending on type of our current observer we need to do different things
            if (temp is DoneObserver!E.instance)
            {
                observer.completed();
                return NopDisposable.instance;
            }

            if (auto fail = cast(DoneObserver!E) temp)
            {
                observer.failure(fail.exception);
                return NopDisposable.instance;
            }

            // if we already have several observers, which is nothing else than a CompositeObserver
            // add one more
            if (auto composite = cast(CompositeObserver!E) temp)
            {
                newObserver = cast(shared) composite.add(observer);
            }
            // if we don't have anything yet, just add the first observer
            else if (auto nop = cast(NopObserver!E) temp)
            {
                newObserver = cast(shared) observer;
            }
            // if we just have one observer, transform it into a CompositveObserver, so that more observers can be added
            // happens only once
            else
            {
                newObserver = cast(shared)(new CompositeObserver!E([temp, observer]));
            }
        }
        // run this loop until newObserver was stored at _observer
        while (!cas(&_observer, oldObserver, newObserver));

        return subscription(this, observer);
    }

    ///
    void unsubscribe(Observer!E observer)
    {
        shared(Observer!E) oldObserver = void;
        shared(Observer!E) newObserver = void;
        do
        {
            oldObserver = _observer;

            import rx.util : assumeThreadLocal;

            auto temp = assumeThreadLocal(atomicLoad(oldObserver));
            if (auto composite = cast(CompositeObserver!E) temp)
            {
                newObserver = cast(shared) composite.remove(observer);
            }
            else
            {
                if (temp !is observer)
                    return;

                newObserver = cast(shared) NopObserver!E.instance;
            }
        }
        while (!cas(&_observer, oldObserver, newObserver));
    }

protected:
    Observer!E currentObserver() @property
    {
        return assumeThreadLocal(atomicLoad(_observer));
    }

private:
    shared(Observer!E) _observer;
}

// @@
// check double subscriptions?
// unittests notifyAdd of non-subscribee
class FilterSubjectObject(E) : SubjectObject!E {
  public:
    this(){
      _filteredObserver = new CompositeObserver!E;
    }

    override void put(E obj){
      if(_filteredObserver.isEmpty){
        super.put(obj);
      } else {
        .put(_filteredObserver, obj);
      }
    }
   
//    override Disposable subscribe(ContextObserver!(T,E) observer){
//      index[][observer.ptr] = observer;
//      return super.subscribe(observer);
//    }

    override void unsubscribe(Observer!E observer){
      super.unsubscribe(observer);
      remove(observer);
    }

    /// manage the list if observers to notify
    void notifyOnly(Observer!E observer){
      _filteredObserver = new CompositeObserver!E;
      notifyOnlyAdd(observer);
    }

    void notifyOnly(Observer!E[] observers){
      _filteredObserver = new CompositeObserver!E(observers);
    }

    void notifyOnlyAdd(Observer!E observer){
      // check that only subscribed observers can be filtered to
      if(auto composite = cast(CompositeObserver!E) currentObserver()){
          if(!composite.isIncluded(observer))
            return;
      } else {
        // special case if the subject has only one observer yet
        if(observer != currentObserver())
          return;
      }

      _filteredObserver = _filteredObserver.add(observer);
    }

    void notifyOnlyAdd(Observer!E[] observers){
      // check that all observers that should be notifiedOnly are subscirbed too
      if(auto composite = cast(CompositeObserver!E) currentObserver()){
        foreach(observer; observers){
          if(!composite.isIncluded(observer))
            return;
        }
      } else {
        foreach(observer; observers){
          if(observer != currentObserver())
            return;
        }
      }

      // all observers are subscribees, so we can add them
      _filteredObserver = _filteredObserver.add(observers);
    }

    void remove(Observer!E observer){
      _filteredObserver = _filteredObserver.removeStrict(observer);
    }
    
  private:
    Observer!E[void*][] index; // AA of arrays which store the observers for quick filter access
    CompositeObserver!E _filteredObserver;
}

///
unittest
{
  import std.stdio;
  writeln("HitTest");

  // void hitTest(E)(Observer!E[] observers, E obj){
  //   // iterate over all hit gobs
  //   // and call .put on these
  //   foreach(observer; observers) {
  //     // check if observer equals what we search for
  //     if(obj == 0)
  //       writeln("Hit at ", obj, "Observer: putCpunt=", observer.putCount);
  //   }
  // }

  import std.range;
  auto subject = new FilterSubjectObject!int;
  auto observer1 = new CounterObserver!int;
  auto observer2 = new CounterObserver!int;
  auto observer3 = new CounterObserver!int;
  
  subject.subscribe(observer1);
  subject.subscribe(observer2);
  subject.subscribe(observer3);

  // send to all observers
  subject.put(1);
  assert(!observer1.hasNotBeenCalled());
  assert(!observer2.hasNotBeenCalled());
  assert(!observer3.hasNotBeenCalled());
  
  assert(observer1.lastValue == 1);
  assert(observer1.putCount  == 1);
  assert(observer2.lastValue == 1);
  assert(observer2.putCount  == 1);
  assert(observer3.lastValue == 1);
  assert(observer3.putCount  == 1);

  // limit the observers that get informed
  subject.notifyOnlyAdd(observer2);
  subject.put(2);
  assert(observer1.lastValue == 1);
  assert(observer1.putCount  == 1);
  assert(observer2.lastValue == 2);
  assert(observer2.putCount  == 2);
  assert(observer3.lastValue == 1);
  assert(observer3.putCount  == 1);

  // limit the observers that get informed, replacing the prior list
  subject.notifyOnly(observer3);
  subject.put(3);
  assert(observer1.lastValue == 1);
  assert(observer1.putCount  == 1);
  assert(observer2.lastValue == 2);
  assert(observer2.putCount  == 2);
  assert(observer3.lastValue == 3);
  assert(observer3.putCount  == 2);

  // inform all
  subject.remove(observer3);
  subject.put(4);
  assert(observer1.lastValue == 4);
  assert(observer1.putCount  == 2);
  assert(observer2.lastValue == 4);
  assert(observer2.putCount  == 3);
  assert(observer3.lastValue == 4);
  assert(observer3.putCount  == 3);

  // unsubscribe observer => doesn't get informed anylonger
  subject.unsubscribe(observer3);
  subject.put(5);
  assert(observer1.lastValue == 5);
  assert(observer1.putCount  == 3);
  assert(observer2.lastValue == 5);
  assert(observer2.putCount  == 4);
  assert(observer3.lastValue == 4);
  assert(observer3.putCount  == 3);

  //double subscribe observer => observer gets called twice on put
  subject.subscribe(observer3);
  subject.subscribe(observer3);
  subject.put(6);
  assert(observer1.lastValue == 6);
  assert(observer1.putCount  == 4);
  assert(observer2.lastValue == 6);
  assert(observer2.putCount  == 5);
  assert(observer3.lastValue == 6);
  assert(observer3.putCount  == 5);
  
  // limit the observers that get informed, replacing the prior list => observer3 gets only called once, even observer is subscribed twice
  //  to have the same behavior notifyOnly needs to be called twice as well
  subject.notifyOnly(observer3);
  subject.put(7);
  assert(observer1.lastValue == 6);
  assert(observer1.putCount  == 4);
  assert(observer2.lastValue == 6);
  assert(observer2.putCount  == 5);
  assert(observer3.lastValue == 7);
  assert(observer3.putCount  == 6);

}

unittest {
  class myClass {
    int putCount;
    int putValue;
    void myPut(int n){
      putValue = n;
      putCount++;
    }

    int completedCount;
    void myCompleted(){
      completedCount++;
    }

    int failurCount;
    void myFailure(Exception e){
      failurCount++;
    }
  }

  myClass mc = new myClass;
  auto observer1 = makeContextObserver(&mc.myPut);

  auto subject = new FilterSubjectObject!int;
  subject.subscribe(observer1);
}

// unittest {
//   import std.stdio;
//   writeln("\n\nRunning: TestFilter unittests");

//   // tests if we can filter an oberserver list on a put() call
//   template putFilter(E) {
//   struct TestFilter(E) {
//     Observer!E _observer;

//     int opApply(int delegate(const Observer!E) foreach_body) const {
//       int result = foreach_body(_observer);
//       return result;
//     }
//   }
//   }

//   void callback(int value) {
//     writeln(value);
//   }

//   auto subject = new SubjectObject!int;
//   auto disposable = subject.doSubscribe!((int value) {callback(value);});
//   assert(disposable !is null);

//   subject.put(0); // normal put();
//   subject.putFiltered(0);

//   writeln("\n\n");

// }

class ContextFilterSubjectObject(E) : SubjectObject!E {
  private:
    
}


unittest
{
    import std.array : appender;

    auto data = appender!(int[])();
    auto subject = new SubjectObject!int;
    auto disposable = subject.subscribe(observerObject!(int)(data));
    assert(disposable !is null);
    subject.put(0);
    subject.put(1);

    import std.algorithm : equal;

    assert(equal(data.data, [0, 1]));

    disposable.dispose();
    subject.put(2);
    assert(equal(data.data, [0, 1]));
}

unittest
{
    static assert(isObserver!(SubjectObject!int, int));
    static assert(isObservable!(SubjectObject!int, int));
    static assert(!isObservable!(SubjectObject!int, string));
    static assert(!isObservable!(SubjectObject!int, string));
}

unittest
{
    auto subject = new SubjectObject!int;
    auto observer = new CounterObserver!int;
    auto disposable = subject.subscribe(observer);
    scope (exit)
        disposable.dispose();

    subject.put(0);
    subject.put(1);

    assert(observer.putCount == 2);
    subject.completed();
    subject.put(2);
    assert(observer.putCount == 2);
    assert(observer.completedCount == 1);
}

unittest
{
    auto subject = new SubjectObject!int;
    auto observer = new CounterObserver!int;
    auto disposable = subject.subscribe(observer);
    scope (exit)
        disposable.dispose();

    subject.put(0);
    subject.put(1);

    assert(observer.putCount == 2);
    auto ex = new Exception("Exception");
    subject.failure(ex);
    subject.put(2);
    assert(observer.putCount == 2);
    assert(observer.failureCount == 1);
    assert(observer.lastException is ex);
}

unittest
{
    import std.array : appender;

    auto buf1 = appender!(int[]);
    auto buf2 = appender!(int[]);
    auto subject = new SubjectObject!int;
    subject.subscribe(observerObject!(int)(buf1));
    subject.doSubscribe((int n) => buf2.put(n));

    assert(buf1.data.length == 0);
    assert(buf2.data.length == 0);
    subject.put(0);
    assert(buf1.data.length == 1);
    assert(buf2.data.length == 1);
    assert(buf1.data[0] == buf2.data[0]);
}

unittest
{
    auto sub = new SubjectObject!int;
    sub.completed();

    auto observer = new CounterObserver!int;
    assert(observer.putCount == 0);
    assert(observer.completedCount == 0);
    assert(observer.failureCount == 0);
    sub.subscribe(observer);
    assert(observer.putCount == 0);
    assert(observer.completedCount == 1);
    assert(observer.failureCount == 0);
}

unittest
{
    auto sub = new SubjectObject!int;
    auto ex = new Exception("Exception");
    sub.failure(ex);

    auto observer = new CounterObserver!int;
    assert(observer.putCount == 0);
    assert(observer.completedCount == 0);
    assert(observer.failureCount == 0);
    sub.subscribe(observer);
    assert(observer.putCount == 0);
    assert(observer.completedCount == 0);
    assert(observer.failureCount == 1);
    assert(observer.lastException is ex);
}

unittest
{
    // MyFilterSubject puts a value only on MyCustomObserver.

    static class MyCustomObserver : Observer!int
    {
        int[] buf;

        void put(int obj)
        {
            buf ~= obj;
        }

        void completed()
        {
        }

        void failure(Exception ex)
        {
        }
    }

    static class MyFilterSubject : SubjectObject!int
    {
        override void put(int obj)
        {
            if (auto current = cast(CompositeObserver!int) currentObserver)
            {
                /// write a own filter, map, order and more  
                foreach (observer; current.observers)
                {
                    if (auto myObserver = cast(MyCustomObserver) observer)
                    {
                        myObserver.put(obj);
                    }
                }
            }
        }
    }

    import std.array : appender;

    auto myObserver = new MyCustomObserver;
    auto buffer = appender!(int[]);

    auto sub = new MyFilterSubject;
    .put(sub, -1);

    sub.subscribe(myObserver);
    sub.subscribe(buffer);

    .put(sub, 0);
    .put(sub, 1);
    .put(sub, 2);

    assert(myObserver.buf.length == 3);
    assert(buffer.data.length == 0);
}

private class Subscription(TSubject, TObserver) : Disposable
{
public:
    this(TSubject subject, TObserver observer)
    {
        _subject = subject;
        _observer = observer;
    }

public:
    void dispose()
    {
        if (_subject !is null)
        {
            _subject.unsubscribe(_observer);
            _subject = null;
        }
    }

private:
    TSubject _subject;
    TObserver _observer;
}

private Subscription!(TSubject, TObserver) subscription(TSubject, TObserver)(
        TSubject subject, TObserver observer)
{
    return new typeof(return)(subject, observer);
}

///
class AsyncSubject(E) : Subject!E
{
public:
    ///
    Disposable subscribe(Observer!E observer)
    {
        Exception ex = null;
        E value;
        bool hasValue = false;

        synchronized (this)
        {
            if (!_isStopped)
            {
                _observers ~= observer;
                return subscription(this, observer);
            }

            ex = _exception;
            hasValue = _hasValue;
            value = _value;
        }

        if (ex !is null)
        {
            observer.failure(ex);
        }
        else if (hasValue)
        {
            .put(observer, value);
            observer.completed();
        }
        else
        {
            observer.completed();
        }

        return NopDisposable.instance;
    }

    ///
    auto subscribe(T)(T observer)
    {
        return subscribe(observerObject!E(observer));
    }

    ///
    void unsubscribe(Observer!E observer)
    {
        if (observer is null)
            return;

        synchronized (this)
        {
            import std.algorithm : remove, countUntil;

            auto index = countUntil(_observers, observer);
            if (index != -1)
            {
                _observers = remove(_observers, index);
            }
        }
    }

public:
    ///
    void put(E value)
    {
        synchronized (this)
        {
            if (!_isStopped)
            {
                _value = value;
                _hasValue = true;
            }
        }
    }

    ///
    void completed()
    {
        Observer!E[] os = null;

        E value;
        bool hasValue = false;

        synchronized (this)
        {
            if (!_isStopped)
            {
                os = _observers;
                _observers.length = 0;
                _isStopped = true;
                value = _value;
                hasValue = _hasValue;
            }
        }

        if (os)
        {
            if (hasValue)
            {
                foreach (observer; os)
                {
                    .put(observer, value);
                    observer.completed();
                }
            }
            else
            {
                foreach (observer; os)
                {
                    observer.completed();
                }
            }
        }
    }

    ///
    void failure(Exception e)
    {
        assert(e !is null);

        Observer!E[] os = null;
        synchronized (this)
        {
            if (!_isStopped)
            {
                os = _observers;
                _observers.length = 0;
                _isStopped = true;
                _exception = e;
            }
        }

        if (os)
        {
            foreach (observer; os)
            {
                observer.failure(e);
            }
        }
    }

private:
    Observer!E[] _observers;
    bool _isStopped;
    E _value;
    bool _hasValue;
    Exception _exception;
}

unittest
{
    auto sub = new AsyncSubject!int;

    .put(sub, 1);
    sub.completed();

    auto observer = new CounterObserver!int;

    assert(observer.hasNotBeenCalled);

    sub.subscribe(observer);

    assert(observer.putCount == 1);
    assert(observer.completedCount == 1);
    assert(observer.failureCount == 0);
    assert(observer.lastValue == 1);
}

unittest
{
    auto sub = new AsyncSubject!int;
    auto observer = new CounterObserver!int;

    auto d = sub.subscribe(observer);
    scope (exit)
        d.dispose();

    assert(observer.hasNotBeenCalled);

    sub.put(100);

    assert(observer.hasNotBeenCalled);

    assert(sub._hasValue);
    assert(sub._value == 100);

    sub.completed();

    assert(observer.putCount == 1);
    assert(observer.completedCount == 1);
    assert(observer.failureCount == 0);
    assert(observer.lastValue == 100);
}

unittest
{
    auto sub = new AsyncSubject!int;
    auto observer = new CounterObserver!int;

    sub.put(100);

    assert(sub._hasValue);
    assert(sub._value == 100);

    auto d = sub.subscribe(observer);
    scope (exit)
        d.dispose();

    assert(observer.hasNotBeenCalled);

    sub.completed();

    assert(observer.putCount == 1);
    assert(observer.completedCount == 1);
    assert(observer.failureCount == 0);
    assert(observer.lastValue == 100);
}

unittest
{
    auto sub = new AsyncSubject!int;
    auto observer = new CounterObserver!int;

    auto d = sub.subscribe(observer);

    d.dispose();
    assert(observer.hasNotBeenCalled);

    sub.put(100);
    assert(observer.hasNotBeenCalled);

    sub.completed();
    assert(observer.hasNotBeenCalled);
}

unittest
{
    auto sub = new AsyncSubject!int;
    auto observer = new CounterObserver!int;

    auto d = sub.subscribe(observer);
    assert(observer.hasNotBeenCalled);

    sub.put(100);
    assert(observer.hasNotBeenCalled);

    d.dispose();
    assert(observer.hasNotBeenCalled);

    sub.completed();
    assert(observer.hasNotBeenCalled);
}

unittest
{

    auto sub = new AsyncSubject!int;
    auto observer = new CounterObserver!int;

    sub.put(100);
    assert(observer.hasNotBeenCalled);

    auto d = sub.subscribe(observer);
    assert(observer.hasNotBeenCalled);

    d.dispose();
    assert(observer.hasNotBeenCalled);

    sub.completed();
    assert(observer.hasNotBeenCalled);
}

unittest
{
    auto sub = new AsyncSubject!int;
    auto observer = new CounterObserver!int;

    auto d = sub.subscribe(observer);
    scope (exit)
        d.dispose();

    assert(observer.hasNotBeenCalled);

    sub.completed();

    assert(observer.putCount == 0);
    assert(observer.completedCount == 1);
    assert(observer.failureCount == 0);
}

unittest
{
    auto sub = new AsyncSubject!int;
    auto observer = new CounterObserver!int;

    auto d = sub.subscribe(observer);
    scope (exit)
        d.dispose();

    assert(observer.hasNotBeenCalled);

    auto ex = new Exception("TEST");
    sub.failure(ex);

    assert(observer.putCount == 0);
    assert(observer.completedCount == 0);
    assert(observer.failureCount == 1);
    assert(observer.lastException is ex);
}

unittest
{
    auto sub = new AsyncSubject!int;
    auto ex = new Exception("TEST");
    sub.failure(ex);

    auto observer = new CounterObserver!int;

    auto d = sub.subscribe(observer);
    scope (exit)
        d.dispose();

    assert(observer.putCount == 0);
    assert(observer.completedCount == 0);
    assert(observer.failureCount == 1);
    assert(observer.lastException is ex);
}

unittest
{
    auto sub = new AsyncSubject!int;
    auto observer = new CounterObserver!int;

    sub.completed();
    assert(observer.hasNotBeenCalled);

    sub.subscribe(observer);
    assert(observer.putCount == 0);
    assert(observer.completedCount == 1);
    assert(observer.failureCount == 0);
}

version (unittest)
{
    class CounterObserver(T) : Observer!T
    {
    public:
        size_t putCount;
        size_t completedCount;
        size_t failureCount;
        T lastValue;
        Exception lastException;

    public:
        bool hasNotBeenCalled() const pure nothrow @nogc @safe @property
        {
            return putCount == 0 && completedCount == 0 && failureCount == 0;
        }

    public:
        void put(T obj)
        {
            putCount++;
            lastValue = obj;
        }

        void completed()
        {
            completedCount++;
        }

        void failure(Exception e)
        {
            failureCount++;
            lastException = e;
        }
    }
}

///
class BehaviorSubject(E) : Subject!E
{
public:
    ///
    this()
    {
        this(E.init);
    }

    ///
    this(E value)
    {
        _subject = new SubjectObject!E;
        _value = value;
    }

public:
    ///
    inout(E) value() inout @property
    {
        return _value;
    }

    ///
    void value(E value) @property
    {
        if (_value != value)
        {
            _value = value;
            .put(_subject, value);
        }
    }

public:
    ///
    auto subscribe(TObserver)(auto ref TObserver observer)
    {
        .put(observer, value);
        return _subject.doSubscribe(observer);
    }

    ///
    Disposable subscribe(Observer!E observer)
    {
        .put(observer, value);
        return disposableObject(_subject.doSubscribe(observer));
    }

    ///
    void put(E obj)
    {
        value = obj;
    }

    ///
    void completed()
    {
        _subject.completed();
    }

    ///
    void failure(Exception e)
    {
        _subject.failure(e);
    }

private:
    SubjectObject!E _subject;
    E _value;
}

unittest
{
    static assert(isObservable!(BehaviorSubject!int, int));
    static assert(is(BehaviorSubject!int.ElementType == int));
}

unittest
{
    int num = 0;
    auto subject = new BehaviorSubject!int(100);

    auto d = subject.doSubscribe((int n) { num = n; });
    assert(num == 100);

    .put(subject, 1);
    assert(num == 1);

    d.dispose();
    .put(subject, 10);
    assert(num == 1);
}

///
auto asBehaviorSubject(TObservable)(auto ref TObservable observable)
{
    alias E = TObservable.ElementType;
    auto subject = new BehaviorSubject!E;
    observable.doSubscribe(subject);
    return subject;
}

///
unittest
{
    import rx;

    auto num1 = new BehaviorSubject!int;
    auto num2 = new BehaviorSubject!int;

    BehaviorSubject!int sum = combineLatest!((l, r) => l + r)(num1, num2).asBehaviorSubject();

    assert(sum.value == 0);
    num1.value = 10;
    assert(sum.value == 10);
    num2.value = 20;
    assert(sum.value == 30);
}

///
class ReplaySubject(E) : Subject!E
{
private:
    RingBuffer!E _buffer;
    SubjectObject!E _subject;
    bool _completed;

public:
    ///
    this(size_t bufferSize)
    {
        _buffer = RingBuffer!E(bufferSize);
        _subject = new SubjectObject!E;
    }

public:
    ///
    Disposable subscribe(TObserver)(auto ref TObserver observer)
    {
        .put(observer, _buffer[]);
        if (_completed)
            return NopDisposable.instance;
        else
            return _subject.doSubscribe(observer).disposableObject();
    }

    ///
    Disposable subscribe(Observer!E observer)
    {
        .put(observer, _buffer[]);
        if (_completed)
            return NopDisposable.instance;
        else
            return disposableObject(_subject.doSubscribe(observer));
    }

    ///
    void put(E obj)
    {
        if (_completed)
            return;
        .put(_buffer, obj);
        .put(_subject, obj);
    }

    ///
    void completed()
    {
        _completed = true;
        _subject.completed();
    }

    ///
    void failure(Exception e)
    {
        _completed = true;
        _subject.failure(e);
    }
}

///
unittest
{
    auto sub = new ReplaySubject!int(1);
    .put(sub, 1);

    int[] buf;
    auto d = sub.doSubscribe!(v => buf ~= v);
    scope (exit)
        d.dispose();

    assert(buf.length == 1);
    assert(buf[0] == 1);
}

///
unittest
{
    auto sub = new ReplaySubject!int(1);
    .put(sub, 1);
    .put(sub, 2);

    int[] buf;
    auto d = sub.doSubscribe!(v => buf ~= v);
    scope (exit)
        d.dispose();

    assert(buf == [2]);
}

///
unittest
{
    auto sub = new ReplaySubject!int(2);
    .put(sub, 1);
    .put(sub, 2);
    .put(sub, 3);

    int[] buf;
    auto d = sub.doSubscribe!(v => buf ~= v);
    scope (exit)
        d.dispose();

    assert(buf == [2, 3]);
}

unittest
{
    auto sub = new ReplaySubject!int(2);
    .put(sub, 1);

    int[] buf;
    auto d = sub.doSubscribe!(v => buf ~= v);
    scope (exit)
        d.dispose();

    .put(sub, 2);

    assert(buf.length == 2);
    assert(buf[0] == 1);
    assert(buf[1] == 2);
}

unittest
{
    auto sub = new ReplaySubject!int(2);
    .put(sub, 1);
    sub.completed();
    .put(sub, 2);

    int[] buf;
    sub.doSubscribe!(v => buf ~= v);

    assert(buf == [1]);
}

unittest
{
    auto sub = new ReplaySubject!int(2);
    .put(sub, 1);
    .put(sub, 2);
    .put(sub, 3);
    sub.completed();
    .put(sub, 4);

    int[] buf;
    sub.doSubscribe!(v => buf ~= v);

    assert(buf == [2, 3]);
}

unittest
{
    auto sub = new ReplaySubject!int(2);
    .put(sub, 1);
    .put(sub, 2);
    .put(sub, 3);
    sub.failure(null);
    .put(sub, 4);

    int[] buf;
    sub.doSubscribe!(v => buf ~= v);

    assert(buf == [2, 3]);
}

private struct RingBuffer(T)
{
    T[] buffer;
    size_t pos;
    size_t count;

    this(size_t n)
    {
        buffer.length = n;
    }

    void put(T obj)
    {
        import std.algorithm : min;

        buffer[pos] = obj;
        pos = (pos + 1) % buffer.length;
        count = min(count + 1, buffer.length);
    }

    RingBufferRange!T opSlice()
    {
        return RingBufferRange!T(buffer, buffer.length - (count - pos), 0, count);
    }
}

unittest
{
    import std.algorithm : equal;
    import std.range : walkLength;

    auto buf = RingBuffer!int(4);

    assert(walkLength(buf[]) == 0);

    buf.put(0);
    assert(buf.buffer.length == 4);
    assert(buf.pos == 1);
    assert(buf.count == 1);
    assert(buf[][0] == 0);
    assert(equal(buf[], [0]));

    buf.put(1);
    assert(buf.buffer.length == 4);
    assert(equal(buf.buffer, [0, 1, 0, 0]));
    assert(buf.pos == 2);
    assert(buf.count == 2);
    assert(buf[][0] == 0);
    assert(buf[][1] == 1);
    assert(equal(buf[], [0, 1]));

    buf.put(2);
    assert(equal(buf[], [0, 1, 2]));

    buf.put(3);
    assert(equal(buf[], [0, 1, 2, 3]));

    buf.put(4);
    assert(equal(buf[], [1, 2, 3, 4]));
}

private struct RingBufferRange(T)
{
    T[] buffer;
    size_t offset;
    size_t pos;
    size_t count;

    bool empty() const @property
    {
        return count == 0 || pos == count;
    }

    inout(T) front() inout @property
    {
        return buffer[(offset + pos) % buffer.length];
    }

    void popFront()
    {
        pos++;
    }

    T opIndex(size_t n)
    {
        return buffer[(offset + pos + n) % buffer.length];
    }
}

unittest
{
    import std.algorithm : equal;

    // no offset
    auto r0 = RingBufferRange!int([0, 1, 2], 0, 0, 2);
    assert(equal(r0, [0, 1]));

    auto r1 = RingBufferRange!int([0, 1, 2], 0, 0, 3);
    assert(equal(r1, [0, 1, 2]));

    auto r2 = RingBufferRange!int([0, 1, 2, 3], 0, 0, 4);
    assert(equal(r2, [0, 1, 2, 3]));

    auto r3 = RingBufferRange!int([0, 1, 2, 3, 4], 0, 0, 5);
    assert(equal(r3, [0, 1, 2, 3, 4]));

    // has offset
    auto r4 = RingBufferRange!int([0, 1, 2, 3], 1, 0, 4);
    assert(!r4.empty);
    assert(r4.front == 1);
    r4.popFront();
    assert(!r4.empty);
    assert(r4.front == 2);
    r4.popFront();
    assert(!r4.empty);
    assert(r4.front == 3);
    r4.popFront();
    assert(!r4.empty);
    assert(r4.front == 0);
    r4.popFront();
    assert(r4.empty);

    auto r5 = RingBufferRange!int([0, 1, 2, 3], 1, 0, 4);
    assert(equal(r5, [1, 2, 3, 0]));

    auto r6 = RingBufferRange!int([0, 1, 2, 3], 2, 0, 4);
    assert(equal(r6, [2, 3, 0, 1]));
}

unittest
{
    import std.algorithm : equal;

    // empty
    auto rempty = RingBufferRange!int([0, 0, 0, 0], 0, 0, 0);
    assert(rempty.empty);

    auto r1 = RingBufferRange!int([1, 0, 0, 0], 0, 0, 1);
    assert(equal(r1, [1]));

    auto r2 = RingBufferRange!int([1, 2, 0, 0], 0, 0, 2);
    assert(equal(r2, [1, 2]));
}

unittest
{
    import std.algorithm : equal;

    // empty
    auto r = RingBufferRange!int([0, 1, 2, 3], 0, 0, 4);
    assert(r[0] == 0);
    assert(r[1] == 1);
    assert(r[2] == 2);
    assert(r[3] == 3);
}

unittest
{
    import std.algorithm : equal;

    // empty
    auto r = RingBufferRange!int([0, 1, 2, 3], 1, 0, 4);
    assert(r[0] == 1);
    assert(r[1] == 2);
    assert(r[2] == 3);
    assert(r[3] == 0);
}

unittest
{
    import std.algorithm : equal;

    // empty
    auto r = RingBufferRange!int([0, 1, 2, 3], 1, 0, 4);
    r.popFront();
    assert(r[0] == 2);
    assert(r[1] == 3);
    assert(r[2] == 0);
}

///
auto asReplaySubject(TObservable)(auto ref TObservable observable, size_t bufferSize)
{
    alias E = TObservable.ElementType;
    auto subject = new ReplaySubject!E(bufferSize);
    observable.doSubscribe(subject);
    return subject;
}

///
unittest
{
    import rx;

    auto sub = defer!(int, (observer) {
        observer.put(10);
        observer.put(20);
        observer.put(30);
        observer.completed();
        return NopDisposable.instance;
    });

    ReplaySubject!int nums = sub.asReplaySubject(4);

    int[] data;
    nums.doSubscribe!(x => data ~= x);

    assert(data == [10, 20, 30]);
}

///
unittest
{
    import rx;

    auto sub = defer!(int, (observer) {
        observer.put(10);
        observer.put(20);
        observer.put(30);
        observer.failure(null);
        return NopDisposable.instance;
    });

    ReplaySubject!int nums = sub.asReplaySubject(2);

    int[] data;
    nums.doSubscribe!(x => data ~= x);

    assert(data == [20, 30]);
}
