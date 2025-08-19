/**
 * Copyright (c) 2010-2016 Yahoo! Inc., 2017 YCSB contributors All rights reserved.
 * <p>
 * Licensed under the Apache License, Version 2.0 (the "License"); you
 * may not use this file except in compliance with the License. You
 * may obtain a copy of the License at
 * <p>
 * http://www.apache.org/licenses/LICENSE-2.0
 * <p>
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 * implied. See the License for the specific language governing
 * permissions and limitations under the License. See accompanying
 * LICENSE file.
 */

package site.ycsb;

import site.ycsb.measurements.Measurements;
import site.ycsb.workloads.CoreWorkload;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.locks.LockSupport;
import java.util.*;

/**
 * A thread for executing transactions or data inserts to the database.
 */
public class ClientThread implements Runnable {
  // Counts down each of the clients completing.
  private final CountDownLatch completeLatch;

  // [Rubble]
  private static int shardNum;
  // [Rubble]
  private static boolean spinSleep;
  private DB db;
  private boolean dotransactions;
  private Workload workload;
  private int opcount;
  private double targetOpsPerMs;

  private int opsdone;
  private int threadid;
  private int threadcount;
  private Object workloadstate;
  private Properties props;
  private long targetOpsTickNs;
  private final Measurements measurements;

  /**
   * Constructor.
   *
   * @param db                   the DB implementation to use
   * @param dotransactions       true to do transactions, false to insert data
   * @param workload             the workload to use
   * @param props                the properties defining the experiment
   * @param opcount              the number of operations (transactions or inserts) to do
   * @param targetperthreadperms target number of operations per thread per ms
   * @param completeLatch        The latch tracking the completion of all clients.
   */
  public ClientThread(DB db, boolean dotransactions, Workload workload, Properties props, int opcount,
                      double targetperthreadperms, CountDownLatch completeLatch) {
    this.db = db;
    this.dotransactions = dotransactions;
    this.workload = workload;
    this.opcount = opcount;
    opsdone = 0;
    if (targetperthreadperms > 0) {
      targetOpsPerMs = targetperthreadperms;
      targetOpsTickNs = (long) (1000000 / targetOpsPerMs);
    }
    this.props = props;
    measurements = Measurements.getMeasurements();
    spinSleep = Boolean.valueOf(this.props.getProperty("spin.sleep", "false"));
    this.completeLatch = completeLatch;
    // [Rubble]
    ((DBWrapper)db).setOpCount(opcount);
    shardNum = Integer.parseInt(this.props.getProperty("shard"));
    // [Rubble]    
  }

  public void setThreadId(final int threadId) {
    threadid = threadId;
    // [Rubble]
    ((DBWrapper)db).setClientIdx(threadid);
    // [Rubble]
  }

  public void setThreadCount(final int threadCount) {
    threadcount = threadCount;
  }

  public int getOpsDone() {
    // [Rubble]
    return db.getOpsDone();
    // [Rubble]
  }

  // [Rubble]
  public void replayTrace(String entry, Random rand) {
    String[] request   = entry.split(",");
    String   key       = request[1];
    int      valueByte = Integer.parseInt(request[3]);
    String   operation = request[5];

    // MODIFIED
    int prevOpsDone = ((DBWrapper)db).getOpsDone();

    if (operation.equals("set") || !dotransactions) {
      byte[] bytes = new byte[valueByte];
      rand.nextBytes(bytes);
      String val = new String(bytes);
      ((DBWrapper)db).insert("usertable", key, null, 0, val);
    } else if (operation.equals("get")) {
      ((DBWrapper)db).read("usertable", key, null, null);
    } else {
      System.out.println("Unsupported! " + operation);
    }

    // MODIFIED
    while ((prevOpsDone + 1) != ((DBWrapper)db).getOpsDone()) {

    }
  }
  // [Rubble]

  @Override
  public void run() {
    try {
      db.init();
      ((DBWrapper)db).setWorkload((CoreWorkload)workload);
    } catch (DBException e) {
      e.printStackTrace();
      e.printStackTrace(System.out);
      return;
    }

    try {
      workloadstate = workload.initThread(props, threadid, threadcount);
    } catch (WorkloadException e) {
      e.printStackTrace();
      e.printStackTrace(System.out);
      return;
    }

    //NOTE: Switching to using nanoTime and parkNanos for time management here such that the measurements
    // and the client thread have the same view on time.

    //spread the thread operations out so they don't all hit the DB at the same time
    // GH issue 4 - throws exception if _target>1 because random.nextInt argument must be >0
    // and the sleep() doesn't make sense for granularities < 1 ms anyway
    if ((targetOpsPerMs > 0) && (targetOpsPerMs <= 1.0)) {
      long randomMinorDelay = ThreadLocalRandom.current().nextInt((int) targetOpsTickNs);
      sleepUntil(System.nanoTime() + randomMinorDelay);
    }
    try {
      if (workload.getClass().equals(CoreWorkload.class) && ((CoreWorkload)workload).isTwitterWorkload()) {
        Random rand = new Random();

        long startTimeNanos = System.nanoTime();
        int lineNumber = 0;

        while (((opcount == 0) || (opsdone < opcount)) && !workload.isStopRequested()) {
          String line = ((CoreWorkload)workload).getTwitterTraceLine(lineNumber);
          if (lineNumber % threadcount == threadid) {
            replayTrace(line, rand);
            opsdone++;
          }
          lineNumber += threadcount;
          // MODIFIED
          throttleNanos(0);
        }
        for (int i = 0; i < shardNum; i++) {
          ((DBWrapper)db).sendBatch(true, i);
          ((DBWrapper)db).sendBatch(false, i);
        }
      } else if (dotransactions) {
        long startTimeNanos = System.nanoTime();

        while (((opcount == 0) || (opsdone < opcount)) && !workload.isStopRequested()) {

          if (!workload.doTransaction(db, workloadstate)) {
            break;
          }

          opsdone++;

          // MODIFIED
          throttleNanos(0);
        }

        // [Rubble]
        for (int i = 0; i < shardNum; i++) {
          ((DBWrapper)db).sendBatch(true, i);
          ((DBWrapper)db).sendBatch(false, i);
        }
        // [Rubble]
      } else {
        long startTimeNanos = System.nanoTime();

        while (((opcount == 0) || (opsdone < opcount)) && !workload.isStopRequested()) {
          // MODIFIED
          int prevOpsDone = ((DBWrapper)db).getOpsDone();

          if (!workload.doInsert(db, workloadstate)) {
            break;
          }

          // MODIFIED
          while ((prevOpsDone + 1) != ((DBWrapper)db).getOpsDone()) {

          }

          opsdone++;

          // MODIFIED
          throttleNanos(0);
        }
        // [Rubble]
        for (int i = 0; i < shardNum; i++) {
          ((DBWrapper)db).sendBatch(true, i);
        }
        // [Rubble]
      }
    } catch (Exception e) {
      e.printStackTrace();
      e.printStackTrace(System.out);
      System.exit(0);
    }

    try {
      measurements.setIntendedStartTimeNs(0);
      while (getOpsDone() < opcount) {
        try {
          Thread.sleep(1);
        } catch (InterruptedException e) {
          e.printStackTrace();
        }
      }
      db.cleanup();
    } catch (DBException e) {
      e.printStackTrace();
      e.printStackTrace(System.out);
    } finally {
      completeLatch.countDown();
    }
  }

  private static void sleepUntil(long deadline) {
    while (System.nanoTime() < deadline) {
      if (!spinSleep) {
        LockSupport.parkNanos(deadline - System.nanoTime());
      }
    }
  }

  private void throttleNanos(long startTimeNanos) {
    //throttle the operations
    if (targetOpsPerMs > 0) {
      // delay until next tick
      long deadline = startTimeNanos + opsdone * targetOpsTickNs;
      sleepUntil(deadline);
      measurements.setIntendedStartTimeNs(deadline);
    }
  }

  /**
   * The total amount of work this thread is still expected to do.
   */
  int getOpsTodo() {
    int todo = opcount - opsdone;
    return todo < 0 ? 0 : todo;
  }
}
