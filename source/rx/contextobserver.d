module rx.contextobserver;

import rx.observer;

interface ContextObserver(T, E) : Observer!E {
  ref T context() @property;
}

// Tests if something has context method.
template hasContext(T)
{
    //dfmt off
    enum bool hasContext = is(typeof({
            T observer = void;
            observer.context();
        }()));
    //dfmt on
}

// Tests if something is ContextObserver.
template isContextObserver(T, E)
{
    enum bool isContextObserver = isObserver!(T, E) && hasContext!T;
}

unittest
{
  class myClass { }

  alias TContextObserver = ContextObserver!(myClass, byte);
  static assert(isObserver!(TContextObserver, byte));
  static assert(isContextObserver!(TContextObserver, byte));
  static assert(hasContext!(TContextObserver));
}

// ContextObserver: stores a reference to some context information
public class ContextObserverObject(T, E) : ContextObserver!E {
  public:
    this(T context){
      _context = context;
    }
    void put(E)
    {
    }

    void completed()
    {
    }

    void failure(Exception)
    {
    }

    ref T context() @property {
      return _context;
    }
  private:
    T _context;
}

// @@ how to write this?
// template contextObserverObject(E){
//  ContextObserverObject!(T,E) contextObserverObject(T)


// template makeContextObserver(T) {
  // auto makeContextObserver(T, E)(ref T context, void delegate(E) doPut, void delegate() doCompleted = null, void delegate(Exception) doFailure = null){
  auto makeContextObserver(E)(void delegate(E) doPut, void delegate() doCompleted = null, void delegate(Exception) doFailure = null){
    static struct AnonymouseContextObserverObject {
      public:
        this(void delegate(E) doPut, void delegate() doCompleted, void delegate(Exception) doFailure)
        {
          _context = doPut.ptr;
          _doPut = doPut;
          _doCompleted = doCompleted;
          _doFailure = doFailure;
        }

      public:
        void put(E obj)
        {
          if (_doPut !is null)
            _doPut(obj);
        }

        void completed()
        {
          if (_doCompleted !is null)
            _doCompleted();
        }

        void failure(Exception e)
        {
          if (_doFailure !is null)
            _doFailure(e);
        }

        void* context() @property {
          return _context;
        }

      private:
        void delegate(E) _doPut;
        void delegate() _doCompleted;
        void delegate(Exception) _doFailure;
        void* _context;
    }

    return AnonymouseContextObserverObject(doPut, doCompleted, doFailure);
  }
// }

unittest
{
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

  // auto observer1 = makeContextObserver!myClass(mc, &mc.myPut);
  auto observer1 = makeContextObserver(&mc.myPut);
  static assert(hasCompleted!(typeof(observer1)));
  static assert(hasFailure!(typeof(observer1)));
  static assert(isObserver!(typeof(observer1), int));
  static assert(isContextObserver!(typeof(observer1), int));
  static assert(hasContext!(typeof(observer1)));

  // works, becaue observer1.context is the refernce to the object
  assert(&mc != observer1.context);
  assert(mc == cast(myClass)observer1.context);
  assert(cast(void*)mc == observer1.context);
}

unittest
{
  class myClassA {
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

  class myClassB {
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

  myClassA mcA = new myClassA;
  myClassB mcB = new myClassB;

  // auto observer1 = makeContextObserver!myClass(mc, &mc.myPut);
  auto observerA = makeContextObserver(&mcA.myPut);
  auto observerB = makeContextObserver(&mcB.myPut);

  // works, becaue observer1.context is the refernce to the object
  assert(mcA == cast(myClassA)observerA.context);
  assert(mcB == cast(myClassB)observerB.context);
  assert(mcA != cast(myClassB)observerB.context);

  import std.stdio;
  writeln(typeof(observerA).stringof);
  writeln(typeof(observerB).stringof);

  // AnonymouseContextObserverObject[] test;
}
